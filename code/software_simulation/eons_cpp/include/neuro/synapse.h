#ifndef NOMAD_NEURO_SYNAPSE_H
#define NOMAD_NEURO_SYNAPSE_H

#include "core/fixed_point.h"
#include <cstdint>

namespace nomad {

/// @brief A synapse connecting a pre-synaptic neuron to a post-synaptic neuron.
///
/// In hardware, synapses are stored as entries in memory clusters.
/// This struct represents one such entry: a connection with a weight and delay.
///
struct Synapse {
    uint8_t  src_neuron;   ///< Pre-synaptic neuron ID.
    uint8_t  dst_neuron;   ///< Post-synaptic neuron ID.
    uint8_t  src_x;        ///< Source tile X (for NOC routing).
    uint8_t  src_y;        ///< Source tile Y.
    uint8_t  dst_x;        ///< Destination tile X.
    uint8_t  dst_y;        ///< Destination tile Y.
    fp16_8   weight;       ///< Synaptic weight (fixed-point).
    uint8_t  delay;        ///< Transmission delay in clock cycles.

    Synapse()
        : src_neuron(0), dst_neuron(0),
          src_x(0), src_y(0), dst_x(0), dst_y(0),
          weight(), delay(1) {}

    Synapse(uint8_t sn, uint8_t dn,
            uint8_t sx, uint8_t sy, uint8_t dx, uint8_t dy,
            fp16_8 w, uint8_t d = 1)
        : src_neuron(sn), dst_neuron(dn),
          src_x(sx), src_y(sy), dst_x(dx), dst_y(dy),
          weight(w), delay(d) {}
};

}  // namespace nomad

#endif  // NOMAD_NEURO_SYNAPSE_H
