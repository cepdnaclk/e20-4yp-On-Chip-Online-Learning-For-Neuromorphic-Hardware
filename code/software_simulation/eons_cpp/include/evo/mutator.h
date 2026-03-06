#ifndef NOMAD_EVO_MUTATOR_H
#define NOMAD_EVO_MUTATOR_H

#include "evo/genotype.h"
#include "evo/prng.h"
#include "core/fixed_point.h"
#include <cstdint>

namespace nomad {

/// @brief Mutation engine for evolutionary algorithm.
///
/// Applies random bit-flip mutations to genotype fields.
/// In hardware, this maps to XOR gates gated by the PRNG output
/// and a probability comparator.
///
/// Mutation types:
///   1. Weight perturbation: add small random noise to synaptic weights.
///   2. Structural mutation: flip connection source/destination IDs.
///   3. Parameter mutation: adjust neuron threshold/leak/refractory.
///
class Mutator {
public:
    /// @param mutation_rate  Probability of mutating each gene (0.0 to 1.0).
    explicit Mutator(float mutation_rate = 0.05f)
        : mutation_rate_(mutation_rate) {}

    /// Mutate a genotype in-place.
    ///
    /// @param genome  Genotype to mutate.
    /// @param prng    PRNG for randomisation.
    ///
    void mutate(Genotype& genome, PRNG& prng) const {
        mutate_neurons(genome, prng);
        mutate_synapses(genome, prng);
    }

    /// Get/set the mutation rate.
    float mutation_rate() const { return mutation_rate_; }
    void set_mutation_rate(float rate) { mutation_rate_ = rate; }

private:
    float mutation_rate_;

    /// Mutate neuron parameters.
    void mutate_neurons(Genotype& genome, PRNG& prng) const {
        for (auto& np : genome.neurons) {
            // Threshold mutation: small perturbation
            if (prng.next_bool(mutation_rate_)) {
                // Add noise in range [-0.25, +0.25]
                fp16_8 noise = fp16_8::from_float((prng.next_float() - 0.5f) * 0.5f);
                np.threshold = np.threshold + noise;
                // Clamp to sensible range
                if (np.threshold < fp16_8::from_float(0.1f)) {
                    np.threshold = fp16_8::from_float(0.1f);
                }
            }

            // Leak rate mutation
            if (prng.next_bool(mutation_rate_)) {
                fp16_8 noise = fp16_8::from_float((prng.next_float() - 0.5f) * 0.1f);
                np.leak_rate = np.leak_rate + noise;
                if (np.leak_rate < fp16_8::zero()) {
                    np.leak_rate = fp16_8::from_float(0.001f);
                }
            }

            // Refractory period mutation
            if (prng.next_bool(mutation_rate_)) {
                int rp = np.refractory_period + (prng.next_bool(0.5f) ? 1 : -1);
                if (rp < 0) rp = 0;
                if (rp > 15) rp = 15;
                np.refractory_period = static_cast<uint8_t>(rp);
            }
        }
    }

    /// Mutate synaptic connections.
    void mutate_synapses(Genotype& genome, PRNG& prng) const {
        uint32_t num_neurons = static_cast<uint32_t>(genome.neurons.size());
        if (num_neurons == 0) return;

        for (auto& syn : genome.synapses) {
            // Weight mutation: perturbation
            if (prng.next_bool(mutation_rate_)) {
                fp16_8 noise = fp16_8::from_float((prng.next_float() - 0.5f) * 0.5f);
                syn.weight = syn.weight + noise;
            }

            // Connection re-wiring: change source or destination neuron
            if (prng.next_bool(mutation_rate_ * 0.5f)) {
                // More conservative: half the mutation rate for structural changes
                if (prng.next_bool(0.5f)) {
                    syn.src_neuron = static_cast<uint8_t>(prng.next_int(num_neurons));
                } else {
                    syn.dst_neuron = static_cast<uint8_t>(prng.next_int(num_neurons));
                }
            }

            // Delay mutation
            if (prng.next_bool(mutation_rate_ * 0.25f)) {
                int d = syn.delay + (prng.next_bool(0.5f) ? 1 : -1);
                if (d < 1) d = 1;
                if (d > 15) d = 15;
                syn.delay = static_cast<uint8_t>(d);
            }
        }
    }
};

}  // namespace nomad

#endif  // NOMAD_EVO_MUTATOR_H
