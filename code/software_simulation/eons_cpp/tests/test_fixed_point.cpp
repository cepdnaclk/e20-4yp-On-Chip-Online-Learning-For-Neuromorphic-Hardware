/// @file test_fixed_point.cpp
/// @brief Unit tests for FixedPoint<TotalBits, IntBits>.
///
/// Uses a simple assert-based test framework (no external dependencies).
/// Run: ./build/test_fixed_point

#include "core/fixed_point.h"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace nomad;

// ── Helpers ───────────────────────────────────────────────────

/// Check that a fixed-point value is within `eps` of the expected float.
template <int T, int I>
void assert_near(FixedPoint<T,I> fp, float expected, float eps = 0.1f) {
    float actual = fp.to_float();
    if (std::fabs(actual - expected) > eps) {
        std::cerr << "FAIL: expected ~" << expected
                  << " but got " << actual
                  << " (raw=" << fp.raw() << ")\n";
        assert(false);
    }
}

// ── Tests ─────────────────────────────────────────────────────

void test_construction() {
    std::cout << "  test_construction ... ";
    fp16_8 a = fp16_8::from_float(1.5f);
    assert_near(a, 1.5f, 0.01f);

    fp16_8 zero;
    assert(zero.raw() == 0);
    assert_near(zero, 0.0f, 0.01f);

    fp16_8 neg = fp16_8::from_float(-3.25f);
    assert_near(neg, -3.25f, 0.1f);
    std::cout << "PASS\n";
}

void test_addition() {
    std::cout << "  test_addition ... ";
    fp16_8 a = fp16_8::from_float(1.5f);
    fp16_8 b = fp16_8::from_float(2.25f);
    auto c = a + b;
    assert_near(c, 3.75f, 0.1f);

    // Negative
    fp16_8 d = fp16_8::from_float(-1.0f);
    auto e = a + d;
    assert_near(e, 0.5f, 0.1f);
    std::cout << "PASS\n";
}

void test_subtraction() {
    std::cout << "  test_subtraction ... ";
    fp16_8 a = fp16_8::from_float(5.0f);
    fp16_8 b = fp16_8::from_float(3.5f);
    auto c = a - b;
    assert_near(c, 1.5f, 0.1f);

    // Result negative
    auto d = b - a;
    assert_near(d, -1.5f, 0.1f);
    std::cout << "PASS\n";
}

void test_multiplication() {
    std::cout << "  test_multiplication ... ";
    fp16_8 a = fp16_8::from_float(2.0f);
    fp16_8 b = fp16_8::from_float(3.5f);
    auto c = a * b;
    assert_near(c, 7.0f, 0.1f);

    fp16_8 d = fp16_8::from_float(-1.5f);
    auto e = a * d;
    assert_near(e, -3.0f, 0.1f);
    std::cout << "PASS\n";
}

void test_division() {
    std::cout << "  test_division ... ";
    fp16_8 a = fp16_8::from_float(7.0f);
    fp16_8 b = fp16_8::from_float(2.0f);
    auto c = a / b;
    assert_near(c, 3.5f, 0.1f);

    // Division by zero → saturate
    fp16_8 zero;
    auto d = a / zero;
    assert(d.raw() == fp16_8::RawMax);
    std::cout << "PASS\n";
}

void test_saturation() {
    std::cout << "  test_saturation ... ";
    // fp8_4: 1 sign + 4 int + 3 frac → range approx [-16, 15.875]
    fp8_4 big = fp8_4::from_float(100.0f);  // should saturate to max
    assert(big.raw() == fp8_4::RawMax);

    fp8_4 small = fp8_4::from_float(-100.0f);  // should saturate to min
    assert(small.raw() == fp8_4::RawMin);
    std::cout << "PASS\n";
}

void test_comparison() {
    std::cout << "  test_comparison ... ";
    fp16_8 a = fp16_8::from_float(1.5f);
    fp16_8 b = fp16_8::from_float(2.0f);
    fp16_8 c = fp16_8::from_float(1.5f);

    assert(a < b);
    assert(b > a);
    assert(a == c);
    assert(a != b);
    assert(a <= c);
    assert(a >= c);
    assert(a <= b);
    std::cout << "PASS\n";
}

void test_bitwise() {
    std::cout << "  test_bitwise ... ";
    fp16_8 a = fp16_8::from_raw(0b0000001110000000);  // some bit pattern
    fp16_8 b = fp16_8::from_raw(0b0000001010000000);

    auto and_result = a.bit_and(b);
    assert(and_result.raw() == (a.raw() & b.raw()));

    auto xor_result = a.bit_xor(b);
    assert(xor_result.raw() == (a.raw() ^ b.raw()));
    std::cout << "PASS\n";
}

void test_negation() {
    std::cout << "  test_negation ... ";
    fp16_8 a = fp16_8::from_float(3.5f);
    auto neg = -a;
    assert_near(neg, -3.5f, 0.1f);

    auto pos = -neg;
    assert_near(pos, 3.5f, 0.1f);
    std::cout << "PASS\n";
}

void test_shift() {
    std::cout << "  test_shift ... ";
    fp16_8 a = fp16_8::from_float(2.0f);
    auto doubled = a << 1;
    assert_near(doubled, 4.0f, 0.1f);

    auto halved = a >> 1;
    assert_near(halved, 1.0f, 0.1f);
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== FixedPoint Tests ===\n";
    test_construction();
    test_addition();
    test_subtraction();
    test_multiplication();
    test_division();
    test_saturation();
    test_comparison();
    test_bitwise();
    test_negation();
    test_shift();
    std::cout << "=== All FixedPoint tests passed ===\n";
    return 0;
}
