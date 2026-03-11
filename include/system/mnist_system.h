#ifndef NOMAD_SYSTEM_MNIST_SYSTEM_H
#define NOMAD_SYSTEM_MNIST_SYSTEM_H

#include "core/fixed_point.h"
#include "core/module.h"
#include "core/signal.h"
#include "env/mnist_environment.h"
#include "env/mnist_loader.h"
#include "evo/evolution_unit.h"
#include "memory/memory_cluster.h"
#include "noc/noc_mesh.h"
#include <iomanip>
#include <iostream>
#include <memory>
#include <vector>

namespace nomad {

/// @brief Top-level NOMAD-EONS system for MNIST digit classification.
///
/// Wires together:
///   - MNISTEnvironment (digit classification task)
///   - Neuromorphic Core (NeuronLIF neurons, NocMesh, MemoryCluster)
///   - Evolutionary Unit (population management, selection, breeding)
///
/// The system orchestrates the evolutionary loop:
///   1. Evaluate each individual's SNN on MNIST samples.
///   2. Log fitness and accuracy statistics.
///   3. Trigger one EU evolutionary cycle.
///   4. Repeat for N generations.
///
/// Usage:
/// @code
///   MNISTLoader loader;
///   loader.load("data/mnist", true, 100);
///   MNISTSystem::Config cfg;
///   cfg.num_generations = 50;
///   MNISTSystem system("mnist_sys", cfg, loader);
///   system.run();
/// @endcode
///
class MNISTSystem : public Module {
public:
  /// System-level configuration.
  struct Config {
    EvolutionUnit::Config eu_config;
    MNISTEnvironment::Config env_config;
    int num_generations; ///< Total evolutionary generations to run.
    int mesh_width;      ///< NOC mesh width.
    int mesh_height;     ///< NOC mesh height.
    uint32_t seed;       ///< Global PRNG seed.
    bool verbose;        ///< Print per-generation details.

    Config()
        : num_generations(30), mesh_width(3), mesh_height(3), seed(0xDEADBEEF),
          verbose(true) {
      // MNIST needs more neurons and synapses than XOR.
      // With pixel_stride=4: 7x7=49 input neurons + 10 output + hidden.
      // Default: 69 neurons (49 input + 10 hidden + 10 output), ~200 synapses.
      env_config.pixel_stride = 4;
      int num_inputs = env_config.num_input_neurons(); // 49
      int num_hidden = 10;
      int num_outputs = env_config.num_output_neurons; // 10

      eu_config.population_size = 20;
      eu_config.num_neurons = num_inputs + num_hidden + num_outputs;
      eu_config.num_synapses = 200;
      eu_config.mutation_rate = 0.08f;
      eu_config.elitism_count = 3;
      eu_config.mesh_width = mesh_width;
      eu_config.mesh_height = mesh_height;
      eu_config.eval_cycles = 100;
    }
  };

  /// @param name   Module name.
  /// @param config System configuration.
  /// @param loader Loaded MNIST dataset.
  MNISTSystem(const std::string &name, const Config &config,
              const MNISTLoader &loader)
      : Module(name), config_(config),
        noc_(std::make_unique<NocMesh>("noc", config.mesh_width,
                                       config.mesh_height)),
        memory_(std::make_unique<MemoryCluster>("mem", 4096)),
        eu_(std::make_unique<EvolutionUnit>("eu", config.eu_config,
                                            config.seed)),
        env_(config.env_config, loader) {
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

  /// @brief Run the full MNIST evolutionary simulation.
  ///
  /// @return The best fitness achieved across all generations.
  ///
  fp16_8 run() {
    initialize();

    fp16_8 overall_best = fp16_8::zero();
    best_fitness_history_.clear();
    accuracy_history_.clear();

    if (config_.verbose) {
      std::cout
          << "╔═══════════════════════════════════════════════════════════════════╗\n";
      std::cout
          << "║          NOMAD-EONS MNIST Evolutionary Simulation               ║\n";
      std::cout
          << "╠═══════════════════════════════════════════════════════════════════╣\n";
      std::cout << "║  Population: " << std::setw(4)
                << config_.eu_config.population_size
                << "  Neurons: " << std::setw(3)
                << config_.eu_config.num_neurons
                << "  Synapses: " << std::setw(3)
                << config_.eu_config.num_synapses << "             ║\n";
      std::cout << "║  Mutation:  " << std::setw(5) << std::fixed
                << std::setprecision(2) << config_.eu_config.mutation_rate
                << "  Elitism: " << std::setw(3)
                << config_.eu_config.elitism_count
                << "  Stride: " << config_.env_config.pixel_stride
                << "  Samples: " << std::setw(3)
                << config_.env_config.num_eval_samples << "   ║\n";
      std::cout
          << "╠═══════════════════════════════════════════════════════════════════╣\n";
      std::cout
          << "║ Gen │ Best Fit │ Avg Fit  │ Worst    │ Accuracy │ Best Ind      ║\n";
      std::cout
          << "╠═════╪══════════╪══════════╪══════════╪══════════╪═══════════════╣\n";
    }

    for (int gen = 0; gen < config_.num_generations; ++gen) {
      // Step 1: Evaluate all individuals using MNISTEnvironment.
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

      // Compute accuracy for the best individual.
      float best_acc = env_.accuracy(pop[best_idx]);
      accuracy_history_.push_back(best_acc);

      if (best > overall_best) {
        overall_best = best;
      }

      if (config_.verbose) {
        std::cout << "║ " << std::setw(3) << gen << " │ " << std::setw(8)
                  << std::fixed << std::setprecision(3) << best.to_float()
                  << " │ " << std::setw(8) << avg << " │ " << std::setw(8)
                  << worst.to_float() << " │ " << std::setw(7)
                  << std::setprecision(1) << (best_acc * 100.0f) << "% │ "
                  << "n=" << std::setw(3) << pop[best_idx].neurons.size()
                  << " s=" << std::setw(3) << pop[best_idx].synapses.size()
                  << "  ║\n";
      }

      // Step 3: Trigger one evolutionary cycle.
      eu_->trigger.write(true);

      int safety_counter = 0;
      do {
        eu_->clk.write(true);
        eu_->clk.write(false);
        safety_counter++;
      } while (eu_->state() != EUState::IDLE && safety_counter < 100);

      eu_->trigger.write(false);
    }

    if (config_.verbose) {
      std::cout
          << "╠═══════════════════════════════════════════════════════════════════╣\n";
      std::cout << "║  Simulation complete: " << config_.num_generations
                << " generations"
                << std::string(40 - std::to_string(config_.num_generations).size(), ' ')
                << "║\n";
      std::cout << "║  Overall best fitness: " << std::setw(8) << std::fixed
                << std::setprecision(3) << overall_best.to_float()
                << "                                        ║\n";
      if (!accuracy_history_.empty()) {
        std::cout << "║  Best accuracy:        " << std::setw(7)
                  << std::setprecision(1) << (accuracy_history_.back() * 100.0f)
                  << "%"
                  << "                                        ║\n";
      }
      std::cout
          << "╚═══════════════════════════════════════════════════════════════════╝\n";
    }

    return overall_best;
  }

  // ── Accessors ────────────────────────────────────────────

  EvolutionUnit &eu() { return *eu_; }
  const EvolutionUnit &eu() const { return *eu_; }
  MNISTEnvironment &env() { return env_; }
  const MNISTEnvironment &env() const { return env_; }
  NocMesh &noc() { return *noc_; }
  const NocMesh &noc() const { return *noc_; }
  MemoryCluster &memory() { return *memory_; }
  const Config &config() const { return config_; }

  /// Fitness history (best per generation).
  const std::vector<fp16_8> &fitness_history() const {
    return best_fitness_history_;
  }

  /// Accuracy history (best individual per generation).
  const std::vector<float> &accuracy_history() const {
    return accuracy_history_;
  }

private:
  Config config_;
  std::unique_ptr<NocMesh> noc_;
  std::unique_ptr<MemoryCluster> memory_;
  std::unique_ptr<EvolutionUnit> eu_;
  MNISTEnvironment env_;

  std::vector<fp16_8> best_fitness_history_;
  std::vector<float> accuracy_history_;
};

} // namespace nomad

#endif // NOMAD_SYSTEM_MNIST_SYSTEM_H
