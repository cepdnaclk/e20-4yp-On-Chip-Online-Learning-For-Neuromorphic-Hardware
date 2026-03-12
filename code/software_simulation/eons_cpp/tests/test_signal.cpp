/// @file test_signal.cpp
/// @brief Unit tests for Signal<T> and Module sensitivity.
///
/// Run: ./build/test_signal

#include "core/signal.h"
#include "core/module.h"
#include <cassert>
#include <iostream>

using namespace nomad;

// ── Test Modules ──────────────────────────────────────────────

/// A simple passthrough module: when input changes, copy it to output.
class PassthroughModule : public Module {
public:
    Signal<int> input{"pt_in"};
    Signal<int> output{"pt_out"};
    int process_count = 0;

    PassthroughModule() : Module("passthrough") {
        sensitive_to(input);
    }

    void process() override {
        output.write(input.read());
        process_count++;
    }
};

/// An inverter module: output = !input (for bool signals).
class InverterModule : public Module {
public:
    Signal<bool> input{"inv_in"};
    Signal<bool> output{"inv_out"};
    int process_count = 0;

    InverterModule() : Module("inverter") {
        sensitive_to(input);
    }

    void process() override {
        output.write(!input.read());
        process_count++;
    }
};

/// A counter module: increments an internal count each time the clock rises.
class CounterModule : public Module {
public:
    Signal<bool> clk{"clk"};
    int count = 0;

    CounterModule() : Module("counter") {
        sensitive_to(clk);
    }

    void process() override {
        if (clk.posedge()) {
            count++;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────

void test_signal_read_write() {
    std::cout << "  test_signal_read_write ... ";
    Signal<int> sig("test_sig");

    assert(sig.read() == 0);  // default-initialised

    sig.write(42);
    assert(sig.read() == 42);

    sig.write(42);  // same value — no event
    assert(sig.read() == 42);

    sig.write(100);
    assert(sig.read() == 100);
    assert(sig.prev() == 42);
    std::cout << "PASS\n";
}

void test_signal_listener() {
    std::cout << "  test_signal_listener ... ";
    Signal<int> sig("listener_sig");
    int callback_count = 0;

    sig.add_listener([&callback_count]() { callback_count++; });

    sig.write(1);   // triggers callback
    assert(callback_count == 1);

    sig.write(1);   // same value — no trigger
    assert(callback_count == 1);

    sig.write(2);   // different value — triggers
    assert(callback_count == 2);
    std::cout << "PASS\n";
}

void test_signal_force() {
    std::cout << "  test_signal_force ... ";
    Signal<int> sig("force_sig");
    int callback_count = 0;
    sig.add_listener([&callback_count]() { callback_count++; });

    sig.force(99);  // should NOT trigger listeners
    assert(sig.read() == 99);
    assert(callback_count == 0);
    std::cout << "PASS\n";
}

void test_module_passthrough() {
    std::cout << "  test_module_passthrough ... ";
    PassthroughModule pt;
    pt.initialize();

    assert(pt.process_count == 0);
    pt.input.write(10);  // triggers process()
    assert(pt.output.read() == 10);
    assert(pt.process_count == 1);

    pt.input.write(20);
    assert(pt.output.read() == 20);
    assert(pt.process_count == 2);

    pt.input.write(20);  // same value — no trigger
    assert(pt.process_count == 2);
    std::cout << "PASS\n";
}

void test_module_chain() {
    std::cout << "  test_module_chain ... ";
    // Chain: source → pt1.input → pt1.output → pt2.input → pt2.output
    PassthroughModule pt1;
    PassthroughModule pt2;
    pt1.set_name("pt1");
    pt2.set_name("pt2");

    // Connect pt1.output to pt2.input
    pt1.output.add_listener([&pt2, &pt1]() {
        pt2.input.write(pt1.output.read());
    });

    pt1.input.write(42);
    assert(pt1.output.read() == 42);
    assert(pt2.input.read() == 42);
    assert(pt2.output.read() == 42);
    std::cout << "PASS\n";
}

void test_posedge_negedge() {
    std::cout << "  test_posedge_negedge ... ";
    Signal<bool> clk("clk");

    clk.force(false);  // initial state

    clk.write(true);   // rising edge
    assert(clk.posedge() == true);
    assert(clk.negedge() == false);

    clk.write(false);  // falling edge
    assert(clk.posedge() == false);
    assert(clk.negedge() == true);
    std::cout << "PASS\n";
}

void test_counter_module() {
    std::cout << "  test_counter_module ... ";
    CounterModule ctr;

    ctr.clk.force(false);

    // Rising edge → count++
    ctr.clk.write(true);
    assert(ctr.count == 1);

    // Falling edge → no increment
    ctr.clk.write(false);
    assert(ctr.count == 1);

    // Rising edge again
    ctr.clk.write(true);
    assert(ctr.count == 2);
    std::cout << "PASS\n";
}

void test_module_hierarchy() {
    std::cout << "  test_module_hierarchy ... ";
    PassthroughModule parent;
    parent.set_name("top");

    InverterModule child1;
    child1.set_name("inv0");

    PassthroughModule child2;
    child2.set_name("pt0");

    parent.add_child(&child1);
    parent.add_child(&child2);

    assert(parent.children().size() == 2);
    assert(parent.children()[0]->name() == "inv0");
    assert(parent.children()[1]->name() == "pt0");

    // Visual check (optional print):
    // parent.print_hierarchy();
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== Signal & Module Tests ===\n";
    test_signal_read_write();
    test_signal_listener();
    test_signal_force();
    test_module_passthrough();
    test_module_chain();
    test_posedge_negedge();
    test_counter_module();
    test_module_hierarchy();
    std::cout << "=== All Signal & Module tests passed ===\n";
    return 0;
}
