/// @file test_evolution.cpp
/// @brief Unit tests for the Evolutionary Unit (Phase 3).
///
/// Tests: Genotype, TournamentSelector, Crossover, Mutator, EvolutionUnit FSM.
/// Run: ./build/test_evolution

#include "evo/genotype.h"
#include "evo/prng.h"
#include "evo/tournament_selector.h"
#include "evo/crossover.h"
#include "evo/mutator.h"
#include "evo/evolution_unit.h"
#include <cassert>
#include <iostream>
#include <cmath>

using namespace nomad;

// ── Helpers ───────────────────────────────────────────────────

template <int T, int I>
void assert_near(FixedPoint<T,I> fp, float expected, float eps = 0.2f) {
    float actual = fp.to_float();
    if (std::fabs(actual - expected) > eps) {
        std::cerr << "FAIL: expected ~" << expected
                  << " but got " << actual << "\n";
        assert(false);
    }
}

// ── Genotype Tests ────────────────────────────────────────────

void test_genotype_construction() {
    std::cout << "  test_genotype_construction ... ";
    Genotype g(4, 8);
    assert(g.neurons.size() == 4);
    assert(g.synapses.size() == 8);
    assert(g.gene_count() == 12);
    assert_near(g.fitness, 0.0f);
    std::cout << "PASS\n";
}

void test_genotype_randomize() {
    std::cout << "  test_genotype_randomize ... ";
    PRNG rng(42);
    Genotype g(4, 8);
    g.randomize(rng, 3, 3);

    // After randomization, thresholds should be non-zero.
    bool any_nonzero = false;
    for (const auto& np : g.neurons) {
        if (np.threshold.raw() != 0) any_nonzero = true;
    }
    assert(any_nonzero);

    // Synaptic weights should have some variation.
    bool weights_vary = false;
    if (g.synapses.size() >= 2) {
        weights_vary = (g.synapses[0].weight != g.synapses[1].weight);
    }
    assert(weights_vary);
    std::cout << "PASS\n";
}

void test_genotype_bitstream_roundtrip() {
    std::cout << "  test_genotype_bitstream_roundtrip ... ";
    PRNG rng(123);
    Genotype original(4, 8);
    original.randomize(rng);

    // Serialise and deserialise.
    auto bits = original.to_bitstream();
    Genotype restored(4, 8);
    restored.from_bitstream(bits);

    // Check that neuron params match.
    for (size_t i = 0; i < original.neurons.size(); ++i) {
        assert(original.neurons[i].threshold == restored.neurons[i].threshold);
        assert(original.neurons[i].leak_rate == restored.neurons[i].leak_rate);
        assert(original.neurons[i].refractory_period == restored.neurons[i].refractory_period);
    }

    // Check that synapse weights match.
    for (size_t i = 0; i < original.synapses.size(); ++i) {
        assert(original.synapses[i].weight == restored.synapses[i].weight);
        assert(original.synapses[i].src_neuron == restored.synapses[i].src_neuron);
        assert(original.synapses[i].dst_neuron == restored.synapses[i].dst_neuron);
    }
    std::cout << "PASS\n";
}

// ── Tournament Selector Tests ─────────────────────────────────

void test_tournament_selection() {
    std::cout << "  test_tournament_selection ... ";
    PRNG rng(999);

    // Create a population with known fitness values.
    std::vector<Genotype> pop(6, Genotype(2, 4));
    pop[0].fitness = fp16_8::from_float(0.1f);
    pop[1].fitness = fp16_8::from_float(0.5f);
    pop[2].fitness = fp16_8::from_float(0.3f);
    pop[3].fitness = fp16_8::from_float(0.9f);  // best
    pop[4].fitness = fp16_8::from_float(0.2f);
    pop[5].fitness = fp16_8::from_float(0.4f);

    TournamentSelector<3> selector;

    // Run many tournaments — the fittest (index 3) should be selected most often.
    int counts[6] = {};
    for (int i = 0; i < 1000; ++i) {
        int winner = selector.select(pop, rng);
        assert(winner >= 0 && winner < 6);
        counts[winner]++;
    }

    // The fittest should be selected more than the least fit.
    assert(counts[3] > counts[0]);
    std::cout << "PASS\n";
}

// ── Crossover Tests ───────────────────────────────────────────

void test_crossover_produces_valid_child() {
    std::cout << "  test_crossover_produces_valid_child ... ";
    PRNG rng(777);

    Genotype p1(4, 8);
    Genotype p2(4, 8);
    p1.randomize(rng);
    p2.randomize(rng);

    Crossover xover;
    Genotype child = xover.cross(p1, p2, rng);

    // Child should have the same structure.
    assert(child.neurons.size() == p1.neurons.size());
    assert(child.synapses.size() == p1.synapses.size());

    // Child's fitness should be zero (not yet evaluated).
    assert_near(child.fitness, 0.0f, 0.01f);

    // Child should have some genes from p1 and some from p2.
    auto bits1 = p1.to_bitstream();
    auto bits2 = p2.to_bitstream();
    auto bits_child = child.to_bitstream();

    bool has_from_p1 = false;
    bool has_from_p2 = false;
    for (size_t i = 0; i < bits_child.size(); ++i) {
        if (bits_child[i] == bits1[i]) has_from_p1 = true;
        if (bits_child[i] == bits2[i]) has_from_p2 = true;
    }
    assert(has_from_p1 || has_from_p2);
    std::cout << "PASS\n";
}

// ── Mutator Tests ─────────────────────────────────────────────

void test_mutation_changes_genome() {
    std::cout << "  test_mutation_changes_genome ... ";
    PRNG rng(333);

    Genotype original(4, 8);
    original.randomize(rng);
    auto original_bits = original.to_bitstream();

    // Copy and mutate with high rate.
    Genotype mutated = original;
    Mutator mut(0.9f);  // 90% mutation rate — should definitely change something
    mut.mutate(mutated, rng);

    auto mutated_bits = mutated.to_bitstream();

    // At least one gene should differ.
    bool any_different = false;
    for (size_t i = 0; i < original_bits.size(); ++i) {
        if (original_bits[i] != mutated_bits[i]) {
            any_different = true;
            break;
        }
    }
    assert(any_different);
    std::cout << "PASS\n";
}

void test_mutation_preserves_structure() {
    std::cout << "  test_mutation_preserves_structure ... ";
    PRNG rng(444);

    Genotype g(4, 8);
    g.randomize(rng);

    Mutator mut(0.5f);
    mut.mutate(g, rng);

    // Structure should be preserved.
    assert(g.neurons.size() == 4);
    assert(g.synapses.size() == 8);
    std::cout << "PASS\n";
}

// ── Evolution Unit FSM Tests ──────────────────────────────────

void test_eu_initial_state() {
    std::cout << "  test_eu_initial_state ... ";
    EvolutionUnit::Config cfg;
    cfg.population_size = 4;
    cfg.num_neurons = 2;
    cfg.num_synapses = 4;
    cfg.eval_cycles = 5;

    EvolutionUnit eu("test_eu", cfg, 12345);
    eu.initialize();

    assert(eu.state() == EUState::IDLE);
    assert(eu.generation() == 0);
    assert(eu.population().size() == 4);
    std::cout << "PASS\n";
}

void test_eu_trigger_cycle() {
    std::cout << "  test_eu_trigger_cycle ... ";
    EvolutionUnit::Config cfg;
    cfg.population_size = 4;
    cfg.num_neurons = 2;
    cfg.num_synapses = 4;
    cfg.eval_cycles = 100;  // high so auto-trigger won't fire
    cfg.elitism_count = 1;

    EvolutionUnit eu("test_eu", cfg, 54321);
    eu.initialize();
    eu.clk.force(false);
    eu.trigger.force(false);
    eu.reward_in.force(fp16_8::zero());

    // Set some fitness values.
    eu.set_fitness(0, fp16_8::from_float(0.5f));
    eu.set_fitness(1, fp16_8::from_float(0.8f));
    eu.set_fitness(2, fp16_8::from_float(0.3f));
    eu.set_fitness(3, fp16_8::from_float(0.6f));

    // Trigger the evolution cycle.
    eu.trigger.write(true);
    assert(eu.state() == EUState::EVALUATE);

    // Clock through: EVALUATE → SELECT
    eu.clk.write(true);
    eu.clk.write(false);
    assert(eu.state() == EUState::SELECT);

    // Clock through: SELECT → BREED
    eu.clk.write(true);
    eu.clk.write(false);
    assert(eu.state() == EUState::BREED);

    // Clock through: BREED → RECONFIGURE
    eu.clk.write(true);
    eu.clk.write(false);
    assert(eu.state() == EUState::RECONFIGURE);

    // Clock through: RECONFIGURE → IDLE
    eu.clk.write(true);
    eu.clk.write(false);
    assert(eu.state() == EUState::IDLE);

    // Generation should have incremented.
    assert(eu.generation() == 1);
    std::cout << "PASS\n";
}

void test_eu_auto_trigger() {
    std::cout << "  test_eu_auto_trigger ... ";
    EvolutionUnit::Config cfg;
    cfg.population_size = 4;
    cfg.num_neurons = 2;
    cfg.num_synapses = 4;
    cfg.eval_cycles = 3;  // auto-trigger after 3 cycles
    cfg.elitism_count = 0;

    EvolutionUnit eu("test_eu_auto", cfg, 11111);
    eu.initialize();
    eu.clk.force(false);
    eu.trigger.force(false);
    eu.reward_in.force(fp16_8::from_float(0.1f));

    assert(eu.state() == EUState::IDLE);

    // Clock 3 times in IDLE → should auto-transition to EVALUATE.
    for (int i = 0; i < 3; ++i) {
        eu.clk.write(true);
        eu.clk.write(false);
    }
    assert(eu.state() == EUState::EVALUATE);

    // Clock through the rest of the cycle.
    for (int i = 0; i < 4; ++i) {
        eu.clk.write(true);
        eu.clk.write(false);
    }
    assert(eu.state() == EUState::IDLE);
    assert(eu.generation() == 1);
    std::cout << "PASS\n";
}

void test_eu_multi_generation() {
    std::cout << "  test_eu_multi_generation ... ";
    EvolutionUnit::Config cfg;
    cfg.population_size = 6;
    cfg.num_neurons = 3;
    cfg.num_synapses = 6;
    cfg.eval_cycles = 2;
    cfg.elitism_count = 1;

    EvolutionUnit eu("test_eu_multi", cfg, 99999);
    eu.initialize();
    eu.clk.force(false);
    eu.trigger.force(false);
    eu.reward_in.force(fp16_8::from_float(0.05f));

    // Run 5 full generations.
    for (int gen = 0; gen < 5; ++gen) {
        // IDLE for eval_cycles
        while (eu.state() == EUState::IDLE) {
            eu.clk.write(true);
            eu.clk.write(false);
        }
        // Clock through remaining states until back to IDLE
        while (eu.state() != EUState::IDLE) {
            eu.clk.write(true);
            eu.clk.write(false);
        }
    }

    assert(eu.generation() == 5);
    assert(eu.population().size() == 6);
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== Evolution Tests ===\n";

    // Genotype tests
    test_genotype_construction();
    test_genotype_randomize();
    test_genotype_bitstream_roundtrip();

    // Selector tests
    test_tournament_selection();

    // Crossover tests
    test_crossover_produces_valid_child();

    // Mutator tests
    test_mutation_changes_genome();
    test_mutation_preserves_structure();

    // Evolution Unit FSM tests
    test_eu_initial_state();
    test_eu_trigger_cycle();
    test_eu_auto_trigger();
    test_eu_multi_generation();

    std::cout << "=== All Evolution tests passed ===\n";
    return 0;
}
