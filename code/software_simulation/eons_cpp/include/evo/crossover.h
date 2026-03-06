#ifndef NOMAD_EVO_CROSSOVER_H
#define NOMAD_EVO_CROSSOVER_H

#include "evo/genotype.h"
#include "evo/prng.h"
#include <vector>
#include <cstdint>

namespace nomad {

/// @brief Single-point crossover operator on genome bitstreams.
///
/// In hardware, this maps to a multiplexer that switches between
/// two memory regions (parent genomes) at the crossover point.
///
/// @code
///   Parent A: [A0 A1 A2 | A3 A4 A5]
///   Parent B: [B0 B1 B2 | B3 B4 B5]
///                       ^-- crossover point
///   Child:    [A0 A1 A2 | B3 B4 B5]
/// @endcode
///
class Crossover {
public:
    Crossover() = default;

    /// Perform single-point crossover between two parents.
    ///
    /// @param parent1  First parent genotype.
    /// @param parent2  Second parent genotype.
    /// @param prng     PRNG for choosing the crossover point.
    /// @return         Child genotype.
    ///
    Genotype cross(const Genotype& parent1, const Genotype& parent2,
                   PRNG& prng) const {
        // Serialise parents to bitstreams.
        auto bits1 = parent1.to_bitstream();
        auto bits2 = parent2.to_bitstream();

        // Use the shorter bitstream length to avoid out-of-bounds.
        size_t len = std::min(bits1.size(), bits2.size());
        if (len == 0) return parent1;  // degenerate case

        // Choose a crossover point in [1, len-1] (at least 1 gene from each parent).
        uint32_t xover_point = 1 + prng.next_int(static_cast<uint32_t>(len - 1));

        // Build child bitstream: parent1[0..xover) + parent2[xover..len).
        std::vector<int32_t> child_bits(len);
        for (size_t i = 0; i < len; ++i) {
            child_bits[i] = (i < xover_point) ? bits1[i] : bits2[i];
        }

        // Reconstruct child genotype with the same structure as parent1.
        Genotype child(static_cast<int>(parent1.neurons.size()),
                       static_cast<int>(parent1.synapses.size()));
        child.from_bitstream(child_bits);
        child.fitness = fp16_8::zero();  // fitness not yet evaluated

        return child;
    }

    /// Uniform crossover: each gene independently chosen from either parent.
    ///
    /// @param parent1  First parent.
    /// @param parent2  Second parent.
    /// @param prng     PRNG for per-gene coin flip.
    /// @return         Child genotype.
    ///
    Genotype uniform_cross(const Genotype& parent1, const Genotype& parent2,
                           PRNG& prng) const {
        auto bits1 = parent1.to_bitstream();
        auto bits2 = parent2.to_bitstream();

        size_t len = std::min(bits1.size(), bits2.size());
        std::vector<int32_t> child_bits(len);

        for (size_t i = 0; i < len; ++i) {
            child_bits[i] = prng.next_bool(0.5f) ? bits1[i] : bits2[i];
        }

        Genotype child(static_cast<int>(parent1.neurons.size()),
                       static_cast<int>(parent1.synapses.size()));
        child.from_bitstream(child_bits);
        child.fitness = fp16_8::zero();

        return child;
    }
};

}  // namespace nomad

#endif  // NOMAD_EVO_CROSSOVER_H
