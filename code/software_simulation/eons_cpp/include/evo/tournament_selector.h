#ifndef NOMAD_EVO_TOURNAMENT_SELECTOR_H
#define NOMAD_EVO_TOURNAMENT_SELECTOR_H

#include "evo/genotype.h"
#include "evo/prng.h"
#include <vector>
#include <cstdint>
#include <cassert>

namespace nomad {

/// @brief Tournament selection for evolutionary algorithm.
///
/// Selects the fittest individual from a random subset (tournament)
/// of the population. In hardware, this maps to a comparator tree
/// over k randomly-addressed fitness registers.
///
/// @tparam K  Tournament size (number of candidates per selection).
///
template <int K = 3>
class TournamentSelector {
    static_assert(K >= 2, "Tournament size must be at least 2");

public:
    TournamentSelector() = default;

    /// Select the index of the winner from the population.
    ///
    /// @param population  Vector of genotypes with fitness scores.
    /// @param prng        PRNG for random candidate selection.
    /// @return            Index of the fittest individual among K random candidates.
    ///
    int select(const std::vector<Genotype>& population, PRNG& prng) const {
        assert(!population.empty() && "Population must not be empty");

        uint32_t pop_size = static_cast<uint32_t>(population.size());

        // Pick the first candidate.
        int best_idx = static_cast<int>(prng.next_int(pop_size));
        fp16_8 best_fitness = population[best_idx].fitness;

        // Compare with K-1 more random candidates.
        for (int i = 1; i < K; ++i) {
            int candidate = static_cast<int>(prng.next_int(pop_size));
            if (population[candidate].fitness > best_fitness) {
                best_idx = candidate;
                best_fitness = population[candidate].fitness;
            }
        }

        return best_idx;
    }

    /// Select two distinct parents.
    ///
    /// @param population  Vector of genotypes with fitness scores.
    /// @param prng        PRNG for random candidate selection.
    /// @return            Pair of (parent1_index, parent2_index).
    ///
    std::pair<int, int> select_parents(const std::vector<Genotype>& population,
                                        PRNG& prng) const {
        int p1 = select(population, prng);
        int p2 = select(population, prng);

        // Try to avoid selecting the same parent (best effort, not guaranteed
        // in hardware — just retry once).
        if (p2 == p1 && population.size() > 1) {
            p2 = select(population, prng);
        }

        return {p1, p2};
    }
};

}  // namespace nomad

#endif  // NOMAD_EVO_TOURNAMENT_SELECTOR_H
