#ifndef NOMAD_ENV_ENVIRONMENT_H
#define NOMAD_ENV_ENVIRONMENT_H

#include "core/fixed_point.h"
#include "core/module.h"
#include "core/signal.h"
#include "evo/genotype.h"
#include "neuro/neuron_lif.h"
#include "neuro/synapse.h"
#include <array>
#include <iostream>
#include <memory>
#include <vector>

namespace nomad {

/// @brief XOR classification environment for evaluating SNN genotypes.
///
/// The Environment acts as the test harness that:
///   1. Configures a set of LIF neurons from a genotype's parameters.
///   2. Injects XOR input patterns as current into designated input neurons.
///   3. Monitors output neuron firing to determine the network's
///   classification.
///   4. Computes a fitness score based on correctness across all 4 XOR
///   patterns.
///
/// XOR truth table:
///   (0,0) → 0
///   (0,1) → 1
///   (1,0) → 1
///   (1,1) → 0
///
/// In hardware, this module would be the external environment interface.
/// Here we implement it as a software evaluation loop for practical simulation.
///
class Environment {
public:
  /// Configuration for the environment.
  struct Config {
    int input_neuron_0;     ///< Index of the first input neuron.
    int input_neuron_1;     ///< Index of the second input neuron.
    int output_neuron;      ///< Index of the output neuron.
    int cycles_per_pattern; ///< Clock cycles to run per XOR pattern.
    fp16_8 input_current;   ///< Current injected for a '1' input.
    fp16_8 spike_threshold; ///< Min spikes to consider output as '1'.

    Config()
        : input_neuron_0(0), input_neuron_1(1), output_neuron(2),
          cycles_per_pattern(20), input_current(fp16_8::from_float(2.0f)),
          spike_threshold(fp16_8::from_float(1.0f)) {}
  };

  explicit Environment(const Config &config = Config()) : config_(config) {}

  /// @brief Evaluate a single genotype on the XOR task.
  ///
  /// Creates temporary neurons from the genotype, wires them with the
  /// genotype's synapses, runs all 4 XOR patterns, and returns a fitness
  /// score in [0, 4] based on the number of correct classifications.
  ///
  /// @param genotype  The SNN genome to evaluate.
  /// @return          Fitness score (fp16_8), higher is better.
  ///
  fp16_8 evaluate(const Genotype &genotype) const {
    int num_neurons = static_cast<int>(genotype.neurons.size());
    if (num_neurons < 3) {
      // Need at least 2 inputs + 1 output neuron.
      return fp16_8::zero();
    }

    // Clamp indices to valid range.
    int in0 = config_.input_neuron_0 % num_neurons;
    int in1 = config_.input_neuron_1 % num_neurons;
    int out = config_.output_neuron % num_neurons;

    // XOR patterns: {input0, input1, expected_output}
    const std::array<std::array<int, 3>, 4> patterns = {
        {{0, 0, 0}, {0, 1, 1}, {1, 0, 1}, {1, 1, 0}}};

    fp16_8 total_fitness = fp16_8::zero();

    for (const auto &pattern : patterns) {
      // Create fresh neurons for each pattern (clean slate).
      std::vector<std::unique_ptr<NeuronLIF>> neurons;
      neurons.reserve(num_neurons);

      for (int i = 0; i < num_neurons; ++i) {
        auto neuron = std::make_unique<NeuronLIF>("eval_n" + std::to_string(i),
                                                  genotype.neurons[i]);
        neuron->initialize();
        neurons.push_back(std::move(neuron));
      }

      // Wire synapses: when a neuron fires, inject weighted current
      // into the destination neuron.
      // We build a synapse lookup: for each source neuron, which
      // destination neurons should receive current.
      struct SynapseEntry {
        int dst_neuron;
        fp16_8 weight;
      };
      std::vector<std::vector<SynapseEntry>> synapse_table(num_neurons);

      for (const auto &syn : genotype.synapses) {
        int src = syn.src_neuron % num_neurons;
        int dst = syn.dst_neuron % num_neurons;
        synapse_table[src].push_back({dst, syn.weight});
      }

      // Run simulation for this pattern.
      for (int cycle = 0; cycle < config_.cycles_per_pattern; ++cycle) {
        // Inject input currents.
        if (pattern[0] == 1) {
          neurons[in0]->inject_current(config_.input_current);
        }
        if (pattern[1] == 1) {
          neurons[in1]->inject_current(config_.input_current);
        }

        // Clock tick: advance all neurons.
        for (auto &neuron : neurons) {
          neuron->clk.write(true);
        }
        for (auto &neuron : neurons) {
          neuron->clk.write(false);
        }

        // Propagate spikes through synapses.
        for (int i = 0; i < num_neurons; ++i) {
          if (neurons[i]->fired.read()) {
            for (const auto &entry : synapse_table[i]) {
              neurons[entry.dst_neuron]->inject_current(entry.weight);
            }
          }
        }
      }

      // Check output: did the output neuron fire?
      uint32_t out_spikes = neurons[out]->spike_count();
      bool output_fired = (out_spikes > 0);
      bool expected = (pattern[2] == 1);

      if (output_fired == expected) {
        // Correct classification: +1.0 fitness.
        total_fitness = total_fitness + fp16_8::from_float(1.0f);
      }

      // Bonus: reward proportional to confidence.
      // If correct, add small bonus for more spikes (or fewer for '0' output).
      if (output_fired == expected) {
        if (expected && out_spikes > 1) {
          total_fitness = total_fitness + fp16_8::from_float(0.1f);
        }
      } else {
        // Partial credit: if expected 1 and got 0, check membrane
        // potential — closer to threshold is better.
        if (expected && !output_fired) {
          fp16_8 membrane = neurons[out]->membrane();
          fp16_8 threshold = genotype.neurons[out].threshold;
          if (threshold > fp16_8::zero()) {
            // Ratio of membrane/threshold, saturated to [0, 0.5].
            fp16_8 ratio = membrane / threshold;
            if (ratio > fp16_8::from_float(0.5f)) {
              ratio = fp16_8::from_float(0.5f);
            }
            if (ratio > fp16_8::zero()) {
              total_fitness = total_fitness + ratio;
            }
          }
        }
      }
    }

    return total_fitness;
  }

  /// @brief Evaluate all individuals in a population and set their fitness.
  ///
  /// This is the main interface called by the system before triggering
  /// the EU's evolutionary cycle.
  ///
  /// @param population  Vector of genotypes (fitness will be written in-place).
  ///
  void evaluate_population(std::vector<Genotype> &population) const {
    for (auto &individual : population) {
      individual.fitness = evaluate(individual);
    }
  }

  const Config &config() const { return config_; }
  Config &config() { return config_; }

private:
  Config config_;
};

} // namespace nomad

#endif // NOMAD_ENV_ENVIRONMENT_H
