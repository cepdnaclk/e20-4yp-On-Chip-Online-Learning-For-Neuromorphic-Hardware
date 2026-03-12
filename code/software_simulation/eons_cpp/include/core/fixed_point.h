#ifndef NOMAD_CORE_FIXED_POINT_H
#define NOMAD_CORE_FIXED_POINT_H

#include <cstdint>
#include <iostream>
#include <type_traits>
#include <limits>
#include <algorithm>

namespace nomad {

/// @brief Hardware-accurate fixed-point arithmetic template.
///
/// Mirrors Verilog fixed-point behaviour: all intermediate results are
/// truncated/saturated to fit within the declared bit-width.
///
/// @tparam TotalBits  Total number of bits (sign + integer + fractional).
/// @tparam IntBits    Number of integer bits (excluding sign bit).
///
/// Layout (signed):  [sign : 1] [integer : IntBits] [fraction : TotalBits - IntBits - 1]
///
/// Example: FixedPoint<16, 8> → 1 sign + 8 integer + 7 fractional bits
///
template <int TotalBits, int IntBits>
class FixedPoint {
    static_assert(TotalBits > 0 && TotalBits <= 32,
                  "TotalBits must be in [1, 32]");
    static_assert(IntBits >= 0 && IntBits < TotalBits,
                  "IntBits must be in [0, TotalBits)");

public:
    /// Number of fractional bits.
    static constexpr int FracBits = TotalBits - IntBits - 1;  // -1 for sign

    /// The scaling factor: 1.0 in fixed-point representation.
    static constexpr int64_t Scale = static_cast<int64_t>(1) << FracBits;

    /// Mask covering TotalBits (unsigned).
    static constexpr int64_t Mask = (static_cast<int64_t>(1) << TotalBits) - 1;

    /// Maximum representable raw value (signed, TotalBits wide).
    static constexpr int32_t RawMax = static_cast<int32_t>((static_cast<int64_t>(1) << (TotalBits - 1)) - 1);

    /// Minimum representable raw value (signed, TotalBits wide).
    static constexpr int32_t RawMin = -static_cast<int32_t>(static_cast<int64_t>(1) << (TotalBits - 1));

    // ── Constructors ──────────────────────────────────────────

    /// Default: zero.
    constexpr FixedPoint() : raw_(0) {}

    /// Construct from a raw integer value (already scaled).
    static constexpr FixedPoint from_raw(int32_t raw) {
        FixedPoint fp;
        fp.raw_ = saturate(raw);
        return fp;
    }

    /// Construct from a floating-point value (for initialisation and testing).
    static FixedPoint from_float(float val) {
        int64_t scaled = static_cast<int64_t>(val * Scale);
        return from_raw(static_cast<int32_t>(scaled));
    }

    static FixedPoint from_double(double val) {
        int64_t scaled = static_cast<int64_t>(val * Scale);
        return from_raw(static_cast<int32_t>(scaled));
    }

    // ── Accessors ─────────────────────────────────────────────

    /// Return the underlying raw integer.
    constexpr int32_t raw() const { return raw_; }

    /// Convert to float (for debugging / logging only — NOT for computation).
    float to_float() const {
        return static_cast<float>(raw_) / static_cast<float>(Scale);
    }

    double to_double() const {
        return static_cast<double>(raw_) / static_cast<double>(Scale);
    }

    // ── Arithmetic operators ──────────────────────────────────

    FixedPoint operator+(const FixedPoint& rhs) const {
        return from_raw(static_cast<int32_t>(
            static_cast<int64_t>(raw_) + static_cast<int64_t>(rhs.raw_)));
    }

    FixedPoint operator-(const FixedPoint& rhs) const {
        return from_raw(static_cast<int32_t>(
            static_cast<int64_t>(raw_) - static_cast<int64_t>(rhs.raw_)));
    }

    FixedPoint operator*(const FixedPoint& rhs) const {
        // Full-precision multiply, then shift back down by FracBits.
        int64_t product = static_cast<int64_t>(raw_) * static_cast<int64_t>(rhs.raw_);
        return from_raw(static_cast<int32_t>(product >> FracBits));
    }

    FixedPoint operator/(const FixedPoint& rhs) const {
        if (rhs.raw_ == 0) {
            // Division by zero → saturate to max or min.
            return from_raw(raw_ >= 0 ? RawMax : RawMin);
        }
        // Pre-shift numerator up by FracBits for precision.
        int64_t num = static_cast<int64_t>(raw_) << FracBits;
        return from_raw(static_cast<int32_t>(num / static_cast<int64_t>(rhs.raw_)));
    }

    FixedPoint operator-() const {
        return from_raw(-raw_);
    }

    FixedPoint& operator+=(const FixedPoint& rhs) { *this = *this + rhs; return *this; }
    FixedPoint& operator-=(const FixedPoint& rhs) { *this = *this - rhs; return *this; }
    FixedPoint& operator*=(const FixedPoint& rhs) { *this = *this * rhs; return *this; }
    FixedPoint& operator/=(const FixedPoint& rhs) { *this = *this / rhs; return *this; }

    // ── Shift operators ───────────────────────────────────────

    FixedPoint operator<<(int shift) const {
        return from_raw(raw_ << shift);
    }

    FixedPoint operator>>(int shift) const {
        return from_raw(raw_ >> shift);  // arithmetic shift (sign-extending)
    }

    // ── Comparison operators ──────────────────────────────────

    constexpr bool operator==(const FixedPoint& rhs) const { return raw_ == rhs.raw_; }
    constexpr bool operator!=(const FixedPoint& rhs) const { return raw_ != rhs.raw_; }
    constexpr bool operator< (const FixedPoint& rhs) const { return raw_ <  rhs.raw_; }
    constexpr bool operator<=(const FixedPoint& rhs) const { return raw_ <= rhs.raw_; }
    constexpr bool operator> (const FixedPoint& rhs) const { return raw_ >  rhs.raw_; }
    constexpr bool operator>=(const FixedPoint& rhs) const { return raw_ >= rhs.raw_; }

    // ── Utility ───────────────────────────────────────────────

    /// Maximum representable value.
    static constexpr FixedPoint max() { return from_raw(RawMax); }

    /// Minimum representable value.
    static constexpr FixedPoint min() { return from_raw(RawMin); }

    /// Zero.
    static constexpr FixedPoint zero() { return FixedPoint(); }

    /// Bitwise AND on the raw representation (useful for masking).
    FixedPoint bit_and(const FixedPoint& rhs) const {
        return from_raw(raw_ & rhs.raw_);
    }

    /// Bitwise OR on the raw representation.
    FixedPoint bit_or(const FixedPoint& rhs) const {
        return from_raw(raw_ | rhs.raw_);
    }

    /// Bitwise XOR on the raw representation.
    FixedPoint bit_xor(const FixedPoint& rhs) const {
        return from_raw(raw_ ^ rhs.raw_);
    }

    /// Bitwise NOT on the raw representation.
    FixedPoint bit_not() const {
        return from_raw(~raw_);
    }

    // ── Stream output ─────────────────────────────────────────

    friend std::ostream& operator<<(std::ostream& os, const FixedPoint& fp) {
        os << fp.to_float() << " [raw=0x" << std::hex << (fp.raw_ & Mask) << std::dec << "]";
        return os;
    }

private:
    int32_t raw_;

    /// Saturate a wider value into the valid range for this fixed-point type.
    static constexpr int32_t saturate(int64_t val) {
        if (val > RawMax) return RawMax;
        if (val < RawMin) return RawMin;
        return static_cast<int32_t>(val);
    }
};

// ── Common type aliases ───────────────────────────────────────
using fp16_8  = FixedPoint<16, 8>;   // 16-bit: 1 sign + 8 int + 7 frac
using fp8_4   = FixedPoint<8, 4>;    // 8-bit:  1 sign + 4 int + 3 frac
using fp32_16 = FixedPoint<32, 16>;  // 32-bit: 1 sign + 16 int + 15 frac

}  // namespace nomad

#endif  // NOMAD_CORE_FIXED_POINT_H
