/// @file test_prng.cpp
/// @brief Unit tests for the PRNG (Xorshift32) module.
///
/// Run: ./build/test_prng

#include "evo/prng.h"
#include <cassert>
#include <iostream>
#include <set>
#include <cmath>

using namespace nomad;

// ── Tests ─────────────────────────────────────────────────────

void test_determinism() {
    std::cout << "  test_determinism ... ";
    PRNG rng1(12345);
    PRNG rng2(12345);

    for (int i = 0; i < 1000; ++i) {
        assert(rng1.next() == rng2.next());
    }
    std::cout << "PASS\n";
}

void test_different_seeds() {
    std::cout << "  test_different_seeds ... ";
    PRNG rng1(111);
    PRNG rng2(222);

    // With different seeds, sequences should diverge.
    bool all_same = true;
    for (int i = 0; i < 100; ++i) {
        if (rng1.next() != rng2.next()) {
            all_same = false;
            break;
        }
    }
    assert(!all_same);
    std::cout << "PASS\n";
}

void test_no_zero_lock() {
    std::cout << "  test_no_zero_lock ... ";
    PRNG rng(0xDEADBEEF);

    // Generate many values and ensure we never get stuck at 0.
    for (int i = 0; i < 10000; ++i) {
        uint32_t val = rng.next();
        assert(val != 0 && "PRNG produced zero — xorshift should never do this");
    }
    std::cout << "PASS\n";
}

void test_uniqueness() {
    std::cout << "  test_uniqueness ... ";
    PRNG rng(42);
    std::set<uint32_t> seen;

    // Generate 1000 values — all should be unique for a good PRNG.
    for (int i = 0; i < 1000; ++i) {
        seen.insert(rng.next());
    }
    assert(seen.size() == 1000 && "PRNG produced duplicate values in 1000 calls");
    std::cout << "PASS\n";
}

void test_next_float_range() {
    std::cout << "  test_next_float_range ... ";
    PRNG rng(99);

    for (int i = 0; i < 1000; ++i) {
        float f = rng.next_float();
        assert(f >= 0.0f && f < 1.0f);
    }
    std::cout << "PASS\n";
}

void test_next_fixed() {
    std::cout << "  test_next_fixed ... ";
    PRNG rng(7777);

    for (int i = 0; i < 1000; ++i) {
        fp16_8 val = rng.next_fixed();
        assert(val.raw() >= fp16_8::RawMin && val.raw() <= fp16_8::RawMax);
    }
    std::cout << "PASS\n";
}

void test_next_int_bound() {
    std::cout << "  test_next_int_bound ... ";
    PRNG rng(555);

    for (int i = 0; i < 1000; ++i) {
        uint32_t val = rng.next_int(10);
        assert(val < 10);
    }

    // Edge case: max_val = 1 → always 0
    for (int i = 0; i < 100; ++i) {
        assert(rng.next_int(1) == 0);
    }
    std::cout << "PASS\n";
}

void test_seed_reset() {
    std::cout << "  test_seed_reset ... ";
    PRNG rng(12345);

    // Generate some values.
    uint32_t first_val = rng.next();
    rng.next();
    rng.next();

    // Reset to the same seed.
    rng.seed(12345);
    uint32_t val_after_reset = rng.next();

    assert(first_val == val_after_reset);
    std::cout << "PASS\n";
}

void test_zero_seed_protection() {
    std::cout << "  test_zero_seed_protection ... ";
    // Zero seed should be internally corrected to avoid zero-lock.
    PRNG rng(0);
    uint32_t val = rng.next();
    assert(val != 0 && "Zero seed should be corrected");
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== PRNG Tests ===\n";
    test_determinism();
    test_different_seeds();
    test_no_zero_lock();
    test_uniqueness();
    test_next_float_range();
    test_next_fixed();
    test_next_int_bound();
    test_seed_reset();
    test_zero_seed_protection();
    std::cout << "=== All PRNG tests passed ===\n";
    return 0;
}
