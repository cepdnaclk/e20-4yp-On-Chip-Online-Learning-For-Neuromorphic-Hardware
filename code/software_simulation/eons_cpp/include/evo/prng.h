#ifndef NOMAD_EVO_PRNG_H
#define NOMAD_EVO_PRNG_H

#include "core/fixed_point.h"
#include <cstdint>

namespace nomad {

/// @brief Hardware-synthesizable 32-bit Xorshift PRNG.
///
/// Implements the xorshift32 algorithm, which maps directly to
/// simple shift-and-XOR operations in hardware (no multipliers needed).
///
/// Verilog-equivalent:
/// @code
///   always @(posedge clk) begin
///       state <= state ^ (state << 13);
///       state <= state ^ (state >> 17);
///       state <= state ^ (state << 5);
///   end
/// @endcode
///
class PRNG {
public:
    /// Construct with a seed. Seed must not be zero (xorshift requirement).
    explicit PRNG(uint32_t seed = 0xDEADBEEF) : state_(seed ? seed : 1) {}

    /// Generate the next 32-bit pseudo-random number.
    uint32_t next() {
        // Xorshift32 (Marsaglia, 2003)
        state_ ^= state_ << 13;
        state_ ^= state_ >> 17;
        state_ ^= state_ << 5;
        return state_;
    }

    /// Generate a float in [0, 1) — for testing/debug only.
    float next_float() {
        return static_cast<float>(next()) / static_cast<float>(UINT32_MAX);
    }

    /// Generate a random fp16_8 in approximately [-max, +max] range.
    /// Useful for random weight generation.
    fp16_8 next_fixed() {
        // Map full 32-bit range to the fixed-point representable range.
        // Take the lower 16 bits and interpret as a signed raw value.
        int32_t raw = static_cast<int16_t>(next() & 0xFFFF);
        // Clamp to fp16_8's valid range
        if (raw > fp16_8::RawMax) raw = fp16_8::RawMax;
        if (raw < fp16_8::RawMin) raw = fp16_8::RawMin;
        return fp16_8::from_raw(raw);
    }

    /// Generate a random unsigned integer in [0, max_val).
    uint32_t next_int(uint32_t max_val) {
        if (max_val == 0) return 0;
        return next() % max_val;
    }

    /// Generate a random boolean with given probability (0.0 = never, 1.0 = always).
    /// Probability is compared against a hardware-friendly threshold.
    bool next_bool(float probability = 0.5f) {
        uint32_t threshold = static_cast<uint32_t>(probability * UINT32_MAX);
        return next() < threshold;
    }

    // ── State management ──────────────────────────────────

    /// Get the current state (for serialisation / debug).
    uint32_t state() const { return state_; }

    /// Re-seed the PRNG.
    void seed(uint32_t s) { state_ = s ? s : 1; }

    /// Reset to the initial seed.
    void reset(uint32_t s) { seed(s); }

private:
    uint32_t state_;
};

}  // namespace nomad

#endif  // NOMAD_EVO_PRNG_H
