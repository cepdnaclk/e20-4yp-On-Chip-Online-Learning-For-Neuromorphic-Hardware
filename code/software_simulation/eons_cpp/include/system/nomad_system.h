#ifndef NOMAD_SYSTEM_NOMAD_SYSTEM_H
#define NOMAD_SYSTEM_NOMAD_SYSTEM_H

#include "core/fixed_point.h"
#include "core/module.h"
#include "core/signal.h"
#include "env/environment.h"
#include "evo/evolution_unit.h"
#include "memory/memory_cluster.h"
#include "neuro/neuron_lif.h"
#include "neuro/synapse.h"
#include "noc/noc_mesh.h"
#include <algorithm>
#include <iomanip>
#include <iostream>
#include <memory>
#include <vector>

namespace nomad {

/// @brief Top-level NOMAD-EONS system integrating all subsystems.
///
/// Wires together:
///   - Environment (XOR classification task)
///   - Neuromorphic Core (NeuronLIF neurons, NocMesh, MemoryCluster)
///   - Evolutionary Unit (population management, selection, breeding)
///
/// The system orchestrates the evolutionary loop:
///   1. Evaluate each individual using the Environment.
///   2. Trigger one EU evolutionary cycle.
///   3. Repeat for N generations.
///
/// Usage:
/// @code
///   NomadSystem::Config cfg;
///   cfg.num_generations = 50;
///   NomadSystem system("nomad", cfg);
///   system.run();
/// @endcode
///
class NomadSystem : public Module {
public:
  /// System-level configuration (aggregates sub-module configs).
  struct Config {
    EvolutionUnit::Config eu_config;
    Environment::Config env_config;
    int num_generations; ///< Total evolutionary generations to run.
    int mesh_width;      ///< NOC mesh width.
    int mesh_height;     ///< NOC mesh height.
    uint32_t seed;       ///< Global PRNG seed.
    bool verbose;        ///< Print per-generation details.

    Config()
        : num_generations(50), mesh_width(2), mesh_height(2), seed(0xDEADBEEF),
          verbose(true) {
      eu_config.population_size = 8;
      eu_config.num_neurons = 4;
      eu_config.num_synapses = 8;
      eu_config.mutation_rate = 0.1f;
      eu_config.elitism_count = 2;
      eu_config.mesh_width = mesh_width;
      eu_config.mesh_height = mesh_height;
      eu_config.eval_cycles = 100; // High: we trigger manually.
    }
  };

  /// @param name   Module name.
  /// @param config System configuration.
  NomadSystem(const std::string &name, const Config &config = Config())
      : Module(name), config_(config),
        noc_(std::make_unique<NocMesh>("noc", config.mesh_width,
                                       config.mesh_height)),
        memory_(std::make_unique<MemoryCluster>("mem", 1024)),
        eu_(std::make_unique<EvolutionUnit>("eu", config.eu_config,
                                            config.seed)),
        env_(config.env_config) {
    add_child(noc_.get());
    add_child(memory_.get());
    add_child(eu_.get());
  }

  void process() override {}

  void initialize() override {
    noc_->initialize();
    memory_->initialize();
    eu_->initialize();
  }

  /// @brief Run the full evolutionary simulation.
  ///
  /// For each generation:
  ///   1. Evaluate all individuals using the Environment.
  ///   2. Log fitness statistics.
  ///   3. Trigger one EU evolutionary cycle (SELECT → BREED → RECONFIGURE).
  ///
  /// @return The best fitness achieved across all generations.
  ///
  fp16_8 run() {
    initialize();

    fp16_8 overall_best = fp16_8::zero();
    best_fitness_history_.clear();

    if (config_.verbose) {
      std::cout
          << "╔═══════════════════════════════════════════════════════════╗\n";
      std::cout
          << "║           NOMAD-EONS Evolutionary Simulation             ║\n";
      std::cout
          << "╠═══════════════════════════════════════════════════════════╣\n";
      std::cout << "║  Population: " << std::setw(4)
                << config_.eu_config.population_size
                << "  Neurons: " << std::setw(3)
                << config_.eu_config.num_neurons
                << "  Synapses: " << std::setw(3)
                << config_.eu_config.num_synapses << "       ║\n";
      std::cout << "║  Mutation:  " << std::setw(5) << std::fixed
                << std::setprecision(2) << config_.eu_config.mutation_rate
                << "  Elitism: " << std::setw(3)
                << config_.eu_config.elitism_count
                << "  Mesh: " << config_.mesh_width << "x"
                << config_.mesh_height << "            ║\n";
      std::cout
          << "╠═══════════════════════════════════════════════════════════╣\n";
      std::cout
          << "║ Gen │ Best Fit │ Avg Fit  │ Worst    │ Best Individual    ║\n";
      std::cout
          << "╠═════╪══════════╪══════════╪══════════╪════════════════════╣\n";
    }

    for (int gen = 0; gen < config_.num_generations; ++gen) {
      // Step 1: Evaluate all individuals in the current population.
      env_.evaluate_population(eu_->population());

      // Step 2: Collect fitness statistics.
      auto &pop = eu_->population();
      fp16_8 best = pop[0].fitness;
      fp16_8 worst = pop[0].fitness;
      float sum = 0.0f;
      int best_idx = 0;

      for (int i = 0; i < static_cast<int>(pop.size()); ++i) {
        if (pop[i].fitness > best) {
          best = pop[i].fitness;
          best_idx = i;
        }
        if (pop[i].fitness < worst) {
          worst = pop[i].fitness;
        }
        sum += pop[i].fitness.to_float();
      }

      float avg = sum / static_cast<float>(pop.size());
      best_fitness_history_.push_back(best);

      if (best > overall_best) {
        overall_best = best;
      }

      if (config_.verbose) {
        std::cout << "║ " << std::setw(3) << gen << " │ " << std::setw(8)
                  << std::fixed << std::setprecision(3) << best.to_float()
                  << " │ " << std::setw(8) << avg << " │ " << std::setw(8)
                  << worst.to_float() << " │ ind[" << std::setw(2) << best_idx
                  << "]" << " n=" << pop[best_idx].neurons.size()
                  << " s=" << pop[best_idx].synapses.size() << "   ║\n";
      }

      // Step 3: Trigger one evolutionary cycle.
      // Set fitness values into the EU (already done via evaluate_population
      // which writes directly to population vector).
      // Now trigger: EVALUATE → SELECT → BREED → RECONFIGURE.
      eu_->trigger.write(true);

      // Clock through the cycle until back to IDLE.
      int safety_counter = 0;
      do {
        eu_->clk.write(true);
        eu_->clk.write(false);
        safety_counter++;
      } while (eu_->state() != EUState::IDLE && safety_counter < 100);

      // Reset trigger — use write() not force() so the EU sees the change
      // and updates its internal trigger_prev_ for rising-edge detection.
      eu_->trigger.write(false);
    }

    if (config_.verbose) {
      std::cout
          << "╠═══════════════════════════════════════════════════════════╣\n";
      std::cout << "║  Simulation complete: " << config_.num_generations
                << " generations                        ║\n";
      std::cout << "║  Overall best fitness: " << std::setw(8) << std::fixed
                << std::setprecision(3) << overall_best.to_float()
                << "                              ║\n";
      std::cout
          << "╚═══════════════════════════════════════════════════════════╝\n";
    }

    return overall_best;
  }

  // ── Accessors ────────────────────────────────────────────

  EvolutionUnit &eu() { return *eu_; }
  const EvolutionUnit &eu() const { return *eu_; }
  Environment &env() { return env_; }
  const Environment &env() const { return env_; }
  NocMesh &noc() { return *noc_; }
  const NocMesh &noc() const { return *noc_; }
  MemoryCluster &memory() { return *memory_; }
  const Config &config() const { return config_; }

  /// Fitness history (best per generation).
  const std::vector<fp16_8> &fitness_history() const {
    return best_fitness_history_;
  }

private:
  Config config_;
  std::unique_ptr<NocMesh> noc_;
  std::unique_ptr<MemoryCluster> memory_;
  std::unique_ptr<EvolutionUnit> eu_;
  Environment env_;

  std::vector<fp16_8> best_fitness_history_;
};

} // namespace nomad

#endif // NOMAD_SYSTEM_NOMAD_SYSTEM_H
