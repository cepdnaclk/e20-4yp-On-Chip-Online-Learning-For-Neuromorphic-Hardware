#ifndef NOMAD_NEURO_SPIKE_PACKET_H
#define NOMAD_NEURO_SPIKE_PACKET_H

#include "core/fixed_point.h"
#include <cstdint>
#include <iostream>

namespace nomad {

/// @brief Spike packet (flit) that travels through the NOC.
///
/// Mirrors a hardware packet with fixed-width fields:
///   [valid:1] [src_x:4] [src_y:4] [dst_x:4] [dst_y:4] [neuron_id:8] [weight:16]
///
/// Total: 41 bits → fits in a 64-bit word for simulation convenience.
///
struct SpikePacket {
    bool     valid;       ///< Packet is valid / contains data.
    uint8_t  src_x;       ///< Source router X coordinate (4 bits, max 15).
    uint8_t  src_y;       ///< Source router Y coordinate.
    uint8_t  dst_x;       ///< Destination router X coordinate.
    uint8_t  dst_y;       ///< Destination router Y coordinate.
    uint8_t  neuron_id;   ///< Neuron ID within the destination tile (8 bits, max 255).
    fp16_8   weight;      ///< Synaptic weight carried with the spike.

    /// Default: invalid packet.
    SpikePacket()
        : valid(false), src_x(0), src_y(0), dst_x(0), dst_y(0),
          neuron_id(0), weight() {}

    /// Construct a valid spike packet.
    SpikePacket(uint8_t sx, uint8_t sy, uint8_t dx, uint8_t dy,
                uint8_t nid, fp16_8 w)
        : valid(true), src_x(sx), src_y(sy), dst_x(dx), dst_y(dy),
          neuron_id(nid), weight(w) {}

    /// Equality: compare all fields (needed by Signal<T> for change detection).
    bool operator==(const SpikePacket& rhs) const {
        return valid == rhs.valid &&
               src_x == rhs.src_x && src_y == rhs.src_y &&
               dst_x == rhs.dst_x && dst_y == rhs.dst_y &&
               neuron_id == rhs.neuron_id &&
               weight == rhs.weight;
    }

    bool operator!=(const SpikePacket& rhs) const { return !(*this == rhs); }

    /// Invalidate this packet.
    void clear() { valid = false; }

    friend std::ostream& operator<<(std::ostream& os, const SpikePacket& p) {
        if (!p.valid) {
            os << "SpikePacket(INVALID)";
        } else {
            os << "SpikePacket(src=" << (int)p.src_x << "," << (int)p.src_y
               << " dst=" << (int)p.dst_x << "," << (int)p.dst_y
               << " nid=" << (int)p.neuron_id
               << " w=" << p.weight << ")";
        }
        return os;
    }
};

}  // namespace nomad

#endif  // NOMAD_NEURO_SPIKE_PACKET_H
