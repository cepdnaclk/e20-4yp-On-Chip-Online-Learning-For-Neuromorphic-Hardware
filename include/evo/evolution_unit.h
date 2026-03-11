#ifndef NOMAD_EVO_EVOLUTION_UNIT_H
#define NOMAD_EVO_EVOLUTION_UNIT_H

#include "core/module.h"
#include "core/signal.h"
#include "core/fixed_point.h"
#include "evo/genotype.h"
#include "evo/prng.h"
#include "evo/tournament_selector.h"
#include "evo/crossover.h"
#include "evo/mutator.h"
#include <vector>
#include <iostream>

namespace nomad {

/// @brief Evolution Unit state machine states.
enum class EUState : int {
    IDLE         = 0,   ///< SNN running; collecting fitness via reward port.
    EVALUATE     = 1,   ///< Computing fitness scores for all individuals.
    SELECT       = 2,   ///< Tournament selection to pick parents.
    BREED        = 3,   ///< Crossover and mutation to produce new genomes.
    RECONFIGURE  = 4    ///< Write new weights/connections to neuromorphic core.
};

/// @brief Equality for Signal<EUState> change detection.
inline bool operator==(EUState a, EUState b) {
    return static_cast<int>(a) == static_cast<int>(b);
}

inline std::ostream& operator<<(std::ostream& os, EUState s) {
    const char* names[] = {"IDLE", "EVALUATE", "SELECT", "BREED", "RECONFIGURE"};
    os << names[static_cast<int>(s)];
    return os;
}

/// @brief Top-level Evolutionary Unit — hardware FSM module.
///
/// Manages a population of SNN genotypes and drives the evolutionary cycle:
///   IDLE → EVALUATE → SELECT → BREED → RECONFIGURE → IDLE
///
/// Ports:
///   - clk          : Clock signal
///   - reward_in    : Fitness/reward value from the environment
///   - trigger      : Start an evolutionary cycle (rising edge)
///   - state_out    : Current FSM state (for observability)
///   - generation   : Current generation counter
///   - config_valid : Asserted when new configuration is ready
///
/// The EU operates as a self-contained hardware module. On each clock
/// posedge it advances through its FSM states, performing one operation
/// per cycle to match hardware pipeline behaviour.
///
class EvolutionUnit : public Module {
public:
    // ── Ports ─────────────────────────────────────────────────
    Signal<bool>     clk{"eu_clk"};
    Signal<fp16_8>   reward_in{"reward_in"};       ///< Fitness from environment.
    Signal<bool>     trigger{"eu_trigger"};         ///< Start evolution cycle.
    Signal<EUState>  state_out{"eu_state"};         ///< Current FSM state.
    Signal<int>      generation_out{"eu_gen"};      ///< Generation counter.
    Signal<bool>     config_valid{"config_valid"};  ///< New config ready flag.

    /// Configuration for the evolution unit.
    struct Config {
        int   population_size;   ///< Number of individuals in the population.
        int   num_neurons;       ///< Neurons per individual.
        int   num_synapses;      ///< Synapses per individual.
        float mutation_rate;     ///< Probability of mutation per gene.
        int   elitism_count;     ///< Number of best individuals preserved.
        int   mesh_width;        ///< NOC mesh width (for coordinate bounds).
        int   mesh_height;       ///< NOC mesh height.
        int   eval_cycles;       ///< Clock cycles to stay in IDLE before evaluating.

        Config()
            : population_size(8), num_neurons(4), num_synapses(8),
              mutation_rate(0.05f), elitism_count(1),
              mesh_width(2), mesh_height(2), eval_cycles(10) {}
    };

    /// @param name   Module instance name.
    /// @param config EU configuration.
    /// @param seed   PRNG seed for reproducibility.
    EvolutionUnit(const std::string& name, const Config& config = Config(),
                  uint32_t seed = 0xDEADBEEF)
        : Module(name), config_(config), prng_(seed),
          mutator_(config.mutation_rate),
          state_(EUState::IDLE), generation_(0),
          idle_counter_(0), current_individual_(0),
          trigger_prev_(false)
    {
        sensitive_to(clk);
        sensitive_to(trigger);

        // Initialise population.
        population_.resize(config_.population_size,
                           Genotype(config_.num_neurons, config_.num_synapses));
        for (auto& ind : population_) {
            ind.randomize(prng_, config_.mesh_width, config_.mesh_height);
        }

        // Prepare offspring buffer.
        offspring_.resize(config_.population_size,
                          Genotype(config_.num_neurons, config_.num_synapses));
    }

    void process() override {
        // Detect trigger rising edge manually (Signal::posedge() doesn't
        // reset, so we track the previous trigger value ourselves).
        bool trigger_now = trigger.read();
        bool trigger_rising = trigger_now && !trigger_prev_;
        trigger_prev_ = trigger_now;

        if (trigger_rising && state_ == EUState::IDLE) {
            transition(EUState::EVALUATE);
            return;
        }

        if (!clk.posedge()) return;

        // FSM: advance one step per clock posedge.
        switch (state_) {
            case EUState::IDLE:
                process_idle();
                break;
            case EUState::EVALUATE:
                process_evaluate();
                break;
            case EUState::SELECT:
                process_select();
                break;
            case EUState::BREED:
                process_breed();
                break;
            case EUState::RECONFIGURE:
                process_reconfigure();
                break;
        }
    }

    void initialize() override {
        state_ = EUState::IDLE;
        generation_ = 0;
        idle_counter_ = 0;
        current_individual_ = 0;
        state_out.force(EUState::IDLE);
        generation_out.force(0);
        trigger_prev_ = false;
        config_valid.force(false);

        // Re-randomize population.
        for (auto& ind : population_) {
            ind.randomize(prng_, config_.mesh_width, config_.mesh_height);
        }
    }

    // ── Accessors ─────────────────────────────────────────────

    EUState state() const { return state_; }
    int generation() const { return generation_; }
    const Config& config() const { return config_; }
    Config& config() { return config_; }

    const std::vector<Genotype>& population() const { return population_; }
    std::vector<Genotype>& population() { return population_; }

    /// Get the best individual (highest fitness) in the current population.
    const Genotype& best_individual() const {
        int best_idx = 0;
        for (size_t i = 1; i < population_.size(); ++i) {
            if (population_[i].fitness > population_[best_idx].fitness) {
                best_idx = static_cast<int>(i);
            }
        }
        return population_[best_idx];
    }

    /// Manually set fitness for an individual (used by environment).
    void set_fitness(int index, fp16_8 fitness) {
        if (index >= 0 && index < static_cast<int>(population_.size())) {
            population_[index].fitness = fitness;
        }
    }

private:
    Config config_;
    PRNG prng_;
    TournamentSelector<3> selector_;
    Crossover crossover_;
    Mutator mutator_;

    EUState state_;
    int generation_;
    int idle_counter_;
    int current_individual_;
    bool trigger_prev_;

    std::vector<Genotype> population_;
    std::vector<Genotype> offspring_;

    // Stored parent indices for BREED state.
    std::vector<std::pair<int, int>> parent_pairs_;

    // ── State transitions ─────────────────────────────────────

    void transition(EUState next) {
        state_ = next;
        state_out.write(next);
    }

    // ── IDLE ──────────────────────────────────────────────────

    void process_idle() {
        config_valid.write(false);

        // Accumulate reward into current individual's fitness.
        population_[current_individual_].fitness =
            population_[current_individual_].fitness + reward_in.read();

        idle_counter_++;

        // Auto-trigger after eval_cycles.
        if (idle_counter_ >= config_.eval_cycles) {
            idle_counter_ = 0;
            transition(EUState::EVALUATE);
        }
    }

    // ── EVALUATE ──────────────────────────────────────────────

    void process_evaluate() {
        // In hardware, this would read fitness registers.
        // Here, fitnesses are already accumulated during IDLE.
        // Just transition to SELECT.
        transition(EUState::SELECT);
    }

    // ── SELECT ────────────────────────────────────────────────

    void process_select() {
        // Perform tournament selection to choose parent pairs.
        parent_pairs_.clear();
        int num_offspring = config_.population_size - config_.elitism_count;

        for (int i = 0; i < num_offspring; ++i) {
            parent_pairs_.push_back(selector_.select_parents(population_, prng_));
        }

        transition(EUState::BREED);
    }

    // ── BREED ─────────────────────────────────────────────────

    void process_breed() {
        // Apply crossover and mutation to produce offspring.
        int num_offspring = config_.population_size - config_.elitism_count;

        for (int i = 0; i < num_offspring; ++i) {
            auto [p1, p2] = parent_pairs_[i];
            offspring_[i] = crossover_.cross(population_[p1], population_[p2], prng_);
            mutator_.mutate(offspring_[i], prng_);
        }

        // Elitism: copy best individuals directly.
        // Sort population by fitness (descending) and keep top elitism_count.
        if (config_.elitism_count > 0) {
            // Find indices of top-k fittest individuals.
            std::vector<int> indices(population_.size());
            for (size_t i = 0; i < indices.size(); ++i) indices[i] = static_cast<int>(i);

            // Partial sort to get top elitism_count.
            for (int e = 0; e < config_.elitism_count && e < static_cast<int>(population_.size()); ++e) {
                for (size_t j = e + 1; j < indices.size(); ++j) {
                    if (population_[indices[j]].fitness > population_[indices[e]].fitness) {
                        std::swap(indices[e], indices[j]);
                    }
                }
                offspring_[num_offspring + e] = population_[indices[e]];
            }
        }

        transition(EUState::RECONFIGURE);
    }

    // ── RECONFIGURE ───────────────────────────────────────────

    void process_reconfigure() {
        // Replace the population with offspring.
        population_ = offspring_;

        // Reset fitness for the new generation.
        for (auto& ind : population_) {
            ind.fitness = fp16_8::zero();
        }

        generation_++;
        generation_out.write(generation_);
        current_individual_ = 0;
        idle_counter_ = 0;

        // Signal that new configuration is ready.
        config_valid.write(true);

        transition(EUState::IDLE);
    }
};

}  // namespace nomad

#endif  // NOMAD_EVO_EVOLUTION_UNIT_H
