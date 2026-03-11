/// @file test_neuron.cpp
/// @brief Unit tests for NeuronLIF.
///
/// Run: ./build/test_neuron

#include "neuro/neuron_lif.h"
#include "core/fixed_point.h"
#include <cassert>
#include <iostream>

using namespace nomad;

// ── Helpers ───────────────────────────────────────────────────

/// Drive one clock cycle on a neuron.
void tick(NeuronLIF& n) {
    n.clk.write(true);
    n.clk.write(false);
}

// ── Tests ─────────────────────────────────────────────────────

void test_initial_state() {
    std::cout << "  test_initial_state ... ";
    NeuronLIF n("n0");
    n.initialize();

    assert(n.membrane() == fp16_8::zero());
    assert(n.spike_count() == 0);
    assert(!n.is_refractory());
    assert(n.fired.read() == false);
    std::cout << "PASS\n";
}

void test_subthreshold_no_fire() {
    std::cout << "  test_subthreshold_no_fire ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(1.0f);
    p.leak_rate = fp16_8::from_float(0.0f);  // no leak for simplicity
    NeuronLIF n("n1", p);
    n.initialize();

    // Inject 0.5 — below threshold of 1.0
    n.inject_current(fp16_8::from_float(0.5f));
    tick(n);

    assert(n.fired.read() == false);
    assert(n.spike_count() == 0);
    // Membrane should be ~ 0.5
    float m = n.membrane().to_float();
    assert(m > 0.3f && m < 0.7f);
    std::cout << "PASS\n";
}

void test_suprathreshold_fires() {
    std::cout << "  test_suprathreshold_fires ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(1.0f);
    p.leak_rate = fp16_8::from_float(0.0f);
    p.reset_potential = fp16_8::from_float(0.0f);
    p.refractory_period = 0;
    NeuronLIF n("n2", p);
    n.initialize();

    // Inject 1.5 — above threshold
    n.inject_current(fp16_8::from_float(1.5f));
    tick(n);

    assert(n.fired.read() == true);
    assert(n.spike_count() == 1);
    // Membrane should be reset to 0
    assert(n.membrane() == fp16_8::zero());
    std::cout << "PASS\n";
}

void test_accumulation_over_ticks() {
    std::cout << "  test_accumulation_over_ticks ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(2.0f);
    p.leak_rate = fp16_8::from_float(0.0f);
    p.reset_potential = fp16_8::from_float(0.0f);
    p.refractory_period = 0;
    NeuronLIF n("n3", p);
    n.initialize();

    // Tick 1: inject 0.8
    n.inject_current(fp16_8::from_float(0.8f));
    tick(n);
    assert(n.fired.read() == false);

    // Tick 2: inject another 0.8 → total ~1.6, still below 2.0
    n.inject_current(fp16_8::from_float(0.8f));
    tick(n);
    assert(n.fired.read() == false);

    // Tick 3: inject 0.8 → total ~2.4, above 2.0 → fire!
    n.inject_current(fp16_8::from_float(0.8f));
    tick(n);
    assert(n.fired.read() == true);
    assert(n.spike_count() == 1);
    std::cout << "PASS\n";
}

void test_leak() {
    std::cout << "  test_leak ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(10.0f);  // high threshold, won't fire
    p.leak_rate = fp16_8::from_float(0.5f);
    p.refractory_period = 0;
    NeuronLIF n("n4", p);
    n.initialize();

    // Inject 2.0
    n.inject_current(fp16_8::from_float(2.0f));
    tick(n);
    // Membrane should be ~ 2.0 - 0.5 = 1.5
    float m1 = n.membrane().to_float();
    assert(m1 > 1.2f && m1 < 1.8f);

    // No input, just leak
    tick(n);
    // Membrane should be ~ 1.5 - 0.5 = 1.0
    float m2 = n.membrane().to_float();
    assert(m2 > 0.7f && m2 < 1.3f);

    // Leak again → ~0.5
    tick(n);
    float m3 = n.membrane().to_float();
    assert(m3 > 0.2f && m3 < 0.8f);

    // Leak again → ~0.0 (clamped to zero)
    tick(n);
    float m4 = n.membrane().to_float();
    assert(m4 >= 0.0f && m4 < 0.3f);
    std::cout << "PASS\n";
}

void test_refractory_period() {
    std::cout << "  test_refractory_period ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(1.0f);
    p.leak_rate = fp16_8::from_float(0.0f);
    p.reset_potential = fp16_8::from_float(0.0f);
    p.refractory_period = 3;
    NeuronLIF n("n5", p);
    n.initialize();

    // Fire the neuron
    n.inject_current(fp16_8::from_float(2.0f));
    tick(n);
    assert(n.fired.read() == true);
    assert(n.is_refractory() == true);

    // Next 3 ticks should be refractory — no firing even with input
    for (int i = 0; i < 3; ++i) {
        n.inject_current(fp16_8::from_float(5.0f));
        tick(n);
        assert(n.fired.read() == false);
    }

    // Tick 5: no longer refractory, inject enough to fire
    assert(n.is_refractory() == false);
    n.inject_current(fp16_8::from_float(2.0f));
    tick(n);
    assert(n.fired.read() == true);
    assert(n.spike_count() == 2);
    std::cout << "PASS\n";
}

void test_spike_output_packet() {
    std::cout << "  test_spike_output_packet ... ";
    NeuronLIF::Params p;
    p.threshold = fp16_8::from_float(1.0f);
    p.leak_rate = fp16_8::from_float(0.0f);
    p.refractory_period = 0;
    p.neuron_id = 7;
    p.tile_x = 2;
    p.tile_y = 3;
    NeuronLIF n("n6", p);

    // Add a synapse target.
    Synapse syn(7, 5, 2, 3, 4, 1, fp16_8::from_float(0.75f));
    n.set_synapses({syn});
    n.initialize();

    n.inject_current(fp16_8::from_float(2.0f));
    tick(n);
    assert(n.fired.read() == true);

    SpikePacket out = n.spike_out.read();
    assert(out.valid == true);
    assert(out.src_x == 2);
    assert(out.src_y == 3);
    assert(out.dst_x == 4);
    assert(out.dst_y == 1);
    assert(out.neuron_id == 5);
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== NeuronLIF Tests ===\n";
    test_initial_state();
    test_subthreshold_no_fire();
    test_suprathreshold_fires();
    test_accumulation_over_ticks();
    test_leak();
    test_refractory_period();
    test_spike_output_packet();
    std::cout << "=== All NeuronLIF tests passed ===\n";
    return 0;
}
