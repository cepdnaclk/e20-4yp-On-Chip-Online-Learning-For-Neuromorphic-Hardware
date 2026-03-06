#ifndef NOMAD_NOC_ARBITER_H
#define NOMAD_NOC_ARBITER_H

#include <cstdint>
#include <array>

namespace nomad {

/// @brief Round-robin arbiter for N request lines.
///
/// In hardware, this resolves contention when multiple input ports
/// want to use the same output port simultaneously.
///
/// @tparam N  Number of requestors (typically 5 for a mesh router).
///
template <int N>
class Arbiter {
public:
    Arbiter() : last_granted_(N - 1) {}

    /// Given a bitmask of requests, return the index of the granted requestor.
    /// Returns -1 if no requests are active.
    ///
    /// Round-robin: starts searching from (last_granted + 1) and wraps around.
    int arbitrate(const std::array<bool, N>& requests) {
        for (int i = 1; i <= N; ++i) {
            int idx = (last_granted_ + i) % N;
            if (requests[idx]) {
                last_granted_ = idx;
                return idx;
            }
        }
        return -1;  // No active request
    }

    /// Reset the arbiter state.
    void reset() { last_granted_ = N - 1; }

    /// Get the last granted index.
    int last_granted() const { return last_granted_; }

private:
    int last_granted_;
};

}  // namespace nomad

#endif  // NOMAD_NOC_ARBITER_H
