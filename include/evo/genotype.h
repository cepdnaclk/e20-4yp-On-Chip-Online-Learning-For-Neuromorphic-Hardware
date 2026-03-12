#ifndef NOMAD_EVO_GENOTYPE_H
#define NOMAD_EVO_GENOTYPE_H

#include "core/fixed_point.h"
#include "neuro/synapse.h"
#include "neuro/neuron_lif.h"
#include "evo/prng.h"
#include <vector>
#include <cstdint>
#include <iostream>

namespace nomad {

/// @brief Genome encoding for a Spiking Neural Network configuration.
///
/// A genotype encodes:
///   1. A list of neuron parameters (one per neuron in the network).
///   2. A list of synaptic connections (source, destination, weight, delay).
///
/// The genome can be serialised to/from a flat bitstream (vector of int32_t)
/// for crossover and mutation operations — mirroring how hardware would
/// store the genome as a contiguous block of memory words.
///
struct Genotype {
    // ── Genome data ──────────────────────────────────────────

    /// Neuron parameters for each neuron in this individual's network.
    std::vector<NeuronLIF::Params> neurons;

    /// Synaptic connections between neurons.
    std::vector<Synapse> synapses;

    /// Fitness score for this individual (higher = better).
    fp16_8 fitness;

    /// Validation accuracy (0.0 to 1.0) used for elitism ranking.
    float val_accuracy;

    // ── Construction ─────────────────────────────────────────

    Genotype() : fitness(fp16_8::zero()), val_accuracy(0.0f) {}

    /// Create a genotype with the given number of neurons and synapses.
    Genotype(int num_neurons, int num_synapses)
        : neurons(num_neurons), synapses(num_synapses),
          fitness(fp16_8::zero()), val_accuracy(0.0f) {}

    // ── Gene count ───────────────────────────────────────────

    /// Total number of "genes" (each neuron param set = 1 gene, each synapse = 1 gene).
    size_t gene_count() const {
        return neurons.size() + synapses.size();
    }

    // ── Randomisation ────────────────────────────────────────

    /// Fill this genotype with random values using the given PRNG.
    /// @param prng      Random number generator.
    /// @param mesh_w    NOC mesh width (for valid tile coordinates).
    /// @param mesh_h    NOC mesh height.
    void randomize(PRNG& prng, int mesh_w = 2, int mesh_h = 2) {
        for (auto& np : neurons) {
            np.threshold = fp16_8::from_float(0.5f + prng.next_float() * 1.5f);
            np.reset_potential = fp16_8::zero();
            np.leak_rate = fp16_8::from_float(0.01f + prng.next_float() * 0.2f);
            np.refractory_period = static_cast<uint8_t>(1 + prng.next_int(4));
            np.tile_x = static_cast<uint8_t>(prng.next_int(mesh_w));
            np.tile_y = static_cast<uint8_t>(prng.next_int(mesh_h));
            np.neuron_id = static_cast<uint8_t>(prng.next_int(16));
        }

        // To ensure the network isn't physically disconnected, we do layered wiring.
        // Assuming typical MNIST config: inputs are first block, outputs are last 10.
        // If not enough neurons, fall back to random wiring.
        int num_n = static_cast<int>(neurons.size());
        int num_inputs = 49; 
        int num_outputs = 10;
        
        if (num_n >= num_inputs + num_outputs) {
            int hidden_start = num_inputs;
            int hidden_end = num_n - num_outputs;
            int num_hidden = hidden_end - hidden_start;
            
            int s = 0;
            // Strategy: 
            // 1. Connect every input to at least 1 hidden (or output if no hidden)
            // 2. Connect every hidden to at least 1 output (or another hidden)
            // 3. Connect remaining synapses randomly but biased forward
            
            // If no hidden layer, strict bipartite
            int target_start = (num_hidden > 0) ? hidden_start : hidden_end;
            int target_size = (num_hidden > 0) ? num_hidden : num_outputs;
            
            for (int i = 0; i < num_inputs && s < static_cast<int>(synapses.size()); ++i) {
                synapses[s].src_neuron = i;
                synapses[s].dst_neuron = target_start + prng.next_int(target_size);
                s++;
            }
            
            if (num_hidden > 0) {
                for (int i = hidden_start; i < hidden_end && s < static_cast<int>(synapses.size()); ++i) {
                    synapses[s].src_neuron = i;
                    synapses[s].dst_neuron = hidden_end + prng.next_int(num_outputs);
                    s++;
                }
            }
            
            // Randomize the rest
            while (s < static_cast<int>(synapses.size())) {
                synapses[s].src_neuron = static_cast<uint8_t>(prng.next_int(num_n));
                synapses[s].dst_neuron = static_cast<uint8_t>(prng.next_int(num_n));
                s++;
            }
        } else {
             for (size_t s = 0; s < synapses.size(); ++s) {
                synapses[s].src_neuron = static_cast<uint8_t>(prng.next_int(num_n));
                synapses[s].dst_neuron = static_cast<uint8_t>(prng.next_int(num_n));
             }
        }

        // Apply metadata and weights
        for (auto& syn : synapses) {
            syn.src_x = static_cast<uint8_t>(prng.next_int(mesh_w));
            syn.src_y = static_cast<uint8_t>(prng.next_int(mesh_h));
            syn.dst_x = static_cast<uint8_t>(prng.next_int(mesh_w));
            syn.dst_y = static_cast<uint8_t>(prng.next_int(mesh_h));
            // Thresholds are generated in [0.5, 2.0]. To ensure firing, weights need larger spread.
            syn.weight = fp16_8::from_float((prng.next_float() - 0.5f) * 6.0f); // Range [-3.0, 3.0]
            syn.delay  = static_cast<uint8_t>(1 + prng.next_int(4));
        }
    }

    // ── Bitstream serialisation ──────────────────────────────

    /// Serialise the genome to a flat vector of int32_t words.
    /// Layout: [neuron params...] [synapse entries...]
    ///
    /// Each neuron: 4 words  (threshold_raw, reset_raw, leak_raw, packed_ids)
    /// Each synapse: 3 words (packed_coords, weight_raw, packed_ids)
    ///
    std::vector<int32_t> to_bitstream() const {
        std::vector<int32_t> bits;
        bits.reserve(neurons.size() * 4 + synapses.size() * 3);

        for (const auto& np : neurons) {
            bits.push_back(np.threshold.raw());
            bits.push_back(np.reset_potential.raw());
            bits.push_back(np.leak_rate.raw());
            // Pack: [refractory:8][neuron_id:8][tile_x:8][tile_y:8]
            int32_t packed = (static_cast<int32_t>(np.refractory_period) << 24) |
                             (static_cast<int32_t>(np.neuron_id) << 16) |
                             (static_cast<int32_t>(np.tile_x) << 8) |
                             (static_cast<int32_t>(np.tile_y));
            bits.push_back(packed);
        }

        for (const auto& syn : synapses) {
            // Pack coords: [src_n:8][dst_n:8][src_x:4][src_y:4][dst_x:4][dst_y:4]
            int32_t coords = (static_cast<int32_t>(syn.src_neuron) << 24) |
                             (static_cast<int32_t>(syn.dst_neuron) << 16) |
                             (static_cast<int32_t>(syn.src_x & 0xF) << 12) |
                             (static_cast<int32_t>(syn.src_y & 0xF) << 8) |
                             (static_cast<int32_t>(syn.dst_x & 0xF) << 4) |
                             (static_cast<int32_t>(syn.dst_y & 0xF));
            bits.push_back(coords);
            bits.push_back(syn.weight.raw());
            bits.push_back(static_cast<int32_t>(syn.delay));
        }

        return bits;
    }

    /// Deserialise from a flat bitstream (inverse of to_bitstream).
    /// The number of neurons and synapses must be set first (via constructor or resize).
    void from_bitstream(const std::vector<int32_t>& bits) {
        size_t idx = 0;
        size_t expected = neurons.size() * 4 + synapses.size() * 3;
        if (bits.size() < expected) return;  // safety

        for (auto& np : neurons) {
            np.threshold = fp16_8::from_raw(bits[idx++]);
            np.reset_potential = fp16_8::from_raw(bits[idx++]);
            np.leak_rate = fp16_8::from_raw(bits[idx++]);
            int32_t packed = bits[idx++];
            np.refractory_period = static_cast<uint8_t>((packed >> 24) & 0xFF);
            np.neuron_id = static_cast<uint8_t>((packed >> 16) & 0xFF);
            np.tile_x = static_cast<uint8_t>((packed >> 8) & 0xFF);
            np.tile_y = static_cast<uint8_t>(packed & 0xFF);
        }

        for (auto& syn : synapses) {
            int32_t coords = bits[idx++];
            syn.src_neuron = static_cast<uint8_t>((coords >> 24) & 0xFF);
            syn.dst_neuron = static_cast<uint8_t>((coords >> 16) & 0xFF);
            syn.src_x = static_cast<uint8_t>((coords >> 12) & 0xF);
            syn.src_y = static_cast<uint8_t>((coords >> 8) & 0xF);
            syn.dst_x = static_cast<uint8_t>((coords >> 4) & 0xF);
            syn.dst_y = static_cast<uint8_t>(coords & 0xF);
            syn.weight = fp16_8::from_raw(bits[idx++]);
            syn.delay = static_cast<uint8_t>(bits[idx++]);
        }
    }

    // ── Debug ────────────────────────────────────────────────

    friend std::ostream& operator<<(std::ostream& os, const Genotype& g) {
        os << "Genotype(neurons=" << g.neurons.size()
           << " synapses=" << g.synapses.size()
           << " fitness=" << g.fitness << ")";
        return os;
    }
};

}  // namespace nomad

#endif  // NOMAD_EVO_GENOTYPE_H
