#ifndef NOMAD_ENV_MNIST_ENVIRONMENT_H
#define NOMAD_ENV_MNIST_ENVIRONMENT_H

#include "core/fixed_point.h"
#include "env/mnist_loader.h"
#include "evo/genotype.h"
#include "neuro/neuron_lif.h"
#include "neuro/synapse.h"
#include <memory>
#include <vector>

namespace nomad {

/// @brief MNIST digit classification environment for evaluating SNN genotypes.
///
/// The MNISTEnvironment acts as the test harness that:
///   1. Configures a set of LIF neurons from a genotype's parameters.
///   2. Rate-codes MNIST pixel intensities as input currents to input neurons.
///   3. Monitors 10 output neurons (one per digit class) to determine
///      the network's classification based on spike counts.
///   4. Computes a fitness score based on correct classifications.
///
/// Input encoding (rate coding):
///   - Pixels are downsampled by `pixel_stride` (e.g., stride=2 → 14x14 = 196
///     input neurons).
///   - Each input neuron receives current proportional to its pixel intensity
///     on each cycle: current = (pixel_value / 255.0) * input_current_scale.
///
/// Output decoding:
///   - 10 output neurons correspond to digits 0–9.
///   - Classification = index of the output neuron with the most spikes.
///   - Ties are broken by earliest first spike (lower index wins).
///
/// Genotype requirements:
///   - neurons.size() >= num_inputs + 10 (inputs + output per digit)
///   - Any additional neurons serve as hidden layer.
///
class MNISTEnvironment {
public:
  /// Configuration for the MNIST environment.
  struct Config {
    int pixel_stride;        ///< Downsample stride (1=full 784, 2=196, 4=49).
    int cycles_per_sample;   ///< Clock cycles to simulate per MNIST sample.
    int num_eval_samples;    ///< How many MNIST samples to evaluate per genotype.
    fp16_8 input_current_scale; ///< Max current for a fully-bright pixel.
    int num_output_neurons;  ///< Always 10 (one per digit).

    Config()
        : pixel_stride(4), cycles_per_sample(30), num_eval_samples(50),
          input_current_scale(fp16_8::from_float(1.5f)),
          num_output_neurons(10) {}

    /// Number of input neurons = downsampled pixel count.
    int num_input_neurons() const {
      int w = 28 / pixel_stride;
      int h = 28 / pixel_stride;
      return w * h;
    }

    /// Minimum neurons a genotype needs: inputs + outputs.
    int min_neurons() const { return num_input_neurons() + num_output_neurons; }
  };

  /// @param config  Environment configuration.
  /// @param loader  Reference to a loaded MNIST dataset.
  explicit MNISTEnvironment(const Config &config, const MNISTLoader &loader)
      : config_(config), loader_(loader) {}

  /// @brief Evaluate a single genotype on MNIST digit classification.
  ///
  /// Creates temporary neurons from the genotype, wires them with the
  /// genotype's synapses, rate-code encodes MNIST pixels as input currents,
  /// simulates for `cycles_per_sample` per image, and returns a fitness
  /// score based on classification accuracy.
  ///
  /// @param genotype  The SNN genome to evaluate.
  /// @return          Fitness score (fp16_8), higher is better.
  ///
  fp16_8 evaluate(const Genotype &genotype) const {
    int num_neurons = static_cast<int>(genotype.neurons.size());
    int num_inputs = config_.num_input_neurons();
    int num_outputs = config_.num_output_neurons;

    if (num_neurons < num_inputs + num_outputs) {
      // Not enough neurons for the MNIST task.
      return fp16_8::zero();
    }

    // Output neurons are the last 10 neurons.
    int output_start = num_neurons - num_outputs;

    // Determine how many samples to evaluate.
    int num_samples = config_.num_eval_samples;
    if (num_samples > loader_.size()) {
      num_samples = loader_.size();
    }
    if (num_samples <= 0) {
      return fp16_8::zero();
    }

    fp16_8 total_fitness = fp16_8::zero();
    int correct_count = 0;

    for (int s = 0; s < num_samples; ++s) {
      const auto &sample = loader_[s];

      // ── Create fresh neurons for this sample ───────────────
      std::vector<std::unique_ptr<NeuronLIF>> neurons;
      neurons.reserve(num_neurons);

      for (int i = 0; i < num_neurons; ++i) {
        auto neuron = std::make_unique<NeuronLIF>(
            "mn" + std::to_string(i), genotype.neurons[i]);
        neuron->initialize();
        neurons.push_back(std::move(neuron));
      }

      // ── Build synapse lookup table ─────────────────────────
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

      // ── Downsample pixel indices ───────────────────────────
      std::vector<int> pixel_indices;
      pixel_indices.reserve(num_inputs);
      for (int y = 0; y < 28; y += config_.pixel_stride) {
        for (int x = 0; x < 28; x += config_.pixel_stride) {
          pixel_indices.push_back(y * 28 + x);
        }
      }

      // ── Simulate for cycles_per_sample clock cycles ────────
      for (int cycle = 0; cycle < config_.cycles_per_sample; ++cycle) {
        // Rate-code input: inject current proportional to pixel intensity.
        for (int i = 0; i < num_inputs && i < static_cast<int>(pixel_indices.size()); ++i) {
          uint8_t pixel = sample.pixels[pixel_indices[i]];
          if (pixel > 0) {
            // Scale pixel value to current.
            float intensity = static_cast<float>(pixel) / 255.0f;
            fp16_8 current =
                fp16_8::from_float(intensity * config_.input_current_scale.to_float());
            neurons[i]->inject_current(current);
          }
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

      // ── Decode output: which digit class got the most spikes? ──
      int predicted = -1;
      uint32_t max_spikes = 0;

      for (int d = 0; d < num_outputs; ++d) {
        uint32_t spikes = neurons[output_start + d]->spike_count();
        if (spikes > max_spikes) {
          max_spikes = spikes;
          predicted = d;
        }
      }

      // ── Score this sample ──────────────────────────────────
      int expected = static_cast<int>(sample.label);

      if (predicted == expected) {
        // Correct classification: +1.0 fitness.
        total_fitness = total_fitness + fp16_8::from_float(1.0f);
        correct_count++;

        // Confidence bonus: more spikes on the correct class is better.
        if (max_spikes > 1) {
          total_fitness = total_fitness + fp16_8::from_float(0.1f);
        }
      } else if (predicted >= 0) {
        // Wrong classification but the network is active.
        // Partial credit: if the correct output neuron fired at all.
        uint32_t correct_spikes = neurons[output_start + expected]->spike_count();
        if (correct_spikes > 0) {
          // Partial credit for having some activity on the correct output.
          float ratio = static_cast<float>(correct_spikes) /
                        static_cast<float>(max_spikes + 1);
          if (ratio > 0.5f) ratio = 0.5f;
          total_fitness = total_fitness + fp16_8::from_float(ratio);
        }
      }
      // If predicted == -1 (no output spikes at all), no fitness awarded.
    }

    return total_fitness;
  }

  /// @brief Evaluate all individuals in a population and set their fitness.
  ///
  /// @param population  Vector of genotypes (fitness will be written in-place).
  ///
  void evaluate_population(std::vector<Genotype> &population) const {
    for (auto &individual : population) {
      individual.fitness = evaluate(individual);
    }
  }

  /// @brief Get the classification accuracy for a genotype.
  ///
  /// Similar to evaluate() but returns accuracy as a float in [0, 1].
  ///
  float accuracy(const Genotype &genotype) const {
    int num_neurons = static_cast<int>(genotype.neurons.size());
    int num_inputs = config_.num_input_neurons();
    int num_outputs = config_.num_output_neurons;

    if (num_neurons < num_inputs + num_outputs) {
      return 0.0f;
    }

    int output_start = num_neurons - num_outputs;
    int num_samples = config_.num_eval_samples;
    if (num_samples > loader_.size())
      num_samples = loader_.size();
    if (num_samples <= 0)
      return 0.0f;

    int correct = 0;

    for (int s = 0; s < num_samples; ++s) {
      const auto &sample = loader_[s];

      std::vector<std::unique_ptr<NeuronLIF>> neurons;
      neurons.reserve(num_neurons);
      for (int i = 0; i < num_neurons; ++i) {
        auto neuron = std::make_unique<NeuronLIF>(
            "an" + std::to_string(i), genotype.neurons[i]);
        neuron->initialize();
        neurons.push_back(std::move(neuron));
      }

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

      std::vector<int> pixel_indices;
      for (int y = 0; y < 28; y += config_.pixel_stride) {
        for (int x = 0; x < 28; x += config_.pixel_stride) {
          pixel_indices.push_back(y * 28 + x);
        }
      }

      for (int cycle = 0; cycle < config_.cycles_per_sample; ++cycle) {
        for (int i = 0; i < static_cast<int>(pixel_indices.size()) &&
                         i < num_neurons;
             ++i) {
          uint8_t pixel = sample.pixels[pixel_indices[i]];
          if (pixel > 0) {
            float intensity = static_cast<float>(pixel) / 255.0f;
            fp16_8 current = fp16_8::from_float(
                intensity * config_.input_current_scale.to_float());
            neurons[i]->inject_current(current);
          }
        }

        for (auto &neuron : neurons) {
          neuron->clk.write(true);
        }
        for (auto &neuron : neurons) {
          neuron->clk.write(false);
        }

        for (int i = 0; i < num_neurons; ++i) {
          if (neurons[i]->fired.read()) {
            for (const auto &entry : synapse_table[i]) {
              neurons[entry.dst_neuron]->inject_current(entry.weight);
            }
          }
        }
      }

      int predicted = -1;
      uint32_t max_spikes = 0;
      for (int d = 0; d < num_outputs; ++d) {
        uint32_t spikes = neurons[output_start + d]->spike_count();
        if (spikes > max_spikes) {
          max_spikes = spikes;
          predicted = d;
        }
      }

      if (predicted == static_cast<int>(sample.label)) {
        correct++;
      }
    }

    return static_cast<float>(correct) / static_cast<float>(num_samples);
  }

  const Config &config() const { return config_; }
  Config &config() { return config_; }

private:
  Config config_;
  const MNISTLoader &loader_;
};

} // namespace nomad

#endif // NOMAD_ENV_MNIST_ENVIRONMENT_H
