#ifndef NOMAD_NOC_ROUTER_H
#define NOMAD_NOC_ROUTER_H

#include "core/module.h"
#include "core/signal.h"
#include "neuro/spike_packet.h"
#include "noc/arbiter.h"
#include <array>
#include <queue>

namespace nomad {

/// @brief Direction indices for a 5-port mesh router.
enum class Direction : int {
    Local = 0,
    North = 1,
    South = 2,
    East  = 3,
    West  = 4,
    COUNT = 5
};

static constexpr int NUM_PORTS = static_cast<int>(Direction::COUNT);

/// @brief 5-port NOC Router with XY routing and input buffering.
///
/// Each router sits at coordinate (pos_x, pos_y) in the mesh.
/// Incoming packets are buffered in per-port FIFOs. On each clock edge,
/// the router reads one packet from each non-empty input buffer,
/// computes the output direction using XY routing, and uses the
/// arbiter to resolve contention.
///
/// Ports:
///   - clk             : Clock
///   - port_in[5]      : Input signals (one per direction)
///   - port_out[5]     : Output signals (one per direction)
///
class Router : public Module {
public:
    // ── Ports ─────────────────────────────────────────────
    Signal<bool> clk{"router_clk"};
    std::array<Signal<SpikePacket>, NUM_PORTS> port_in;
    std::array<Signal<SpikePacket>, NUM_PORTS> port_out;

    /// @param name     Module instance name.
    /// @param x        X coordinate in the mesh.
    /// @param y        Y coordinate in the mesh.
    /// @param buf_depth Input buffer depth per port (default 4).
    Router(const std::string& name, uint8_t x, uint8_t y, int buf_depth = 4)
        : Module(name), pos_x_(x), pos_y_(y), buf_depth_(buf_depth)
    {
        // Name the port signals for debugging.
        const char* dir_names[] = {"local", "north", "south", "east", "west"};
        for (int i = 0; i < NUM_PORTS; ++i) {
            port_in[i]  = Signal<SpikePacket>(std::string(name) + "_in_"  + dir_names[i]);
            port_out[i] = Signal<SpikePacket>(std::string(name) + "_out_" + dir_names[i]);
        }

        // Sensitive to clock and all input ports.
        sensitive_to(clk);
        for (int i = 0; i < NUM_PORTS; ++i) {
            sensitive_to(port_in[i]);
        }
    }

    void process() override {
        // Buffer incoming packets (combinational — react to input changes).
        for (int i = 0; i < NUM_PORTS; ++i) {
            const auto& pkt = port_in[i].read();
            if (pkt.valid && static_cast<int>(input_buffers_[i].size()) < buf_depth_) {
                input_buffers_[i].push(pkt);
                // Clear the input to avoid re-buffering on next event.
                // (In real hardware, the upstream would de-assert valid.)
            }
        }

        // On clock rising edge: route buffered packets.
        if (clk.posedge()) {
            route_packets();
        }
    }

    void initialize() override {
        for (int i = 0; i < NUM_PORTS; ++i) {
            while (!input_buffers_[i].empty()) input_buffers_[i].pop();
            port_out[i].force(SpikePacket());
        }
        for (auto& arb : output_arbiters_) arb.reset();
        packets_routed_ = 0;
        packets_dropped_ = 0;
    }

    // ── Accessors ─────────────────────────────────────────

    uint8_t pos_x() const { return pos_x_; }
    uint8_t pos_y() const { return pos_y_; }
    uint32_t packets_routed() const { return packets_routed_; }
    uint32_t packets_dropped() const { return packets_dropped_; }

    /// Number of packets currently buffered across all ports.
    int buffered_count() const {
        int count = 0;
        for (int i = 0; i < NUM_PORTS; ++i) {
            count += static_cast<int>(input_buffers_[i].size());
        }
        return count;
    }

private:
    uint8_t pos_x_;
    uint8_t pos_y_;
    int buf_depth_;
    uint32_t packets_routed_ = 0;
    uint32_t packets_dropped_ = 0;

    std::array<std::queue<SpikePacket>, NUM_PORTS> input_buffers_;
    std::array<Arbiter<NUM_PORTS>, NUM_PORTS> output_arbiters_;

    /// XY Routing: determine output direction for a packet.
    Direction xy_route(const SpikePacket& pkt) const {
        if (pkt.dst_x < pos_x_) return Direction::West;
        if (pkt.dst_x > pos_x_) return Direction::East;
        if (pkt.dst_y < pos_y_) return Direction::North;
        if (pkt.dst_y > pos_y_) return Direction::South;
        return Direction::Local;  // destination is this router
    }

    /// Route one cycle's worth of packets from input buffers.
    void route_packets() {
        // Track which output ports have been claimed this cycle.
        std::array<bool, NUM_PORTS> output_busy = {false};

        // Build request matrix: requests[output][input] = wants to use output.
        std::array<std::array<bool, NUM_PORTS>, NUM_PORTS> requests = {};

        // For each input port, peek at the head packet and determine its output.
        std::array<Direction, NUM_PORTS> desired_output = {};
        for (int i = 0; i < NUM_PORTS; ++i) {
            if (!input_buffers_[i].empty()) {
                desired_output[i] = xy_route(input_buffers_[i].front());
                int out_idx = static_cast<int>(desired_output[i]);
                requests[out_idx][i] = true;
            }
        }

        // For each output port, arbitrate among requesting inputs.
        for (int out = 0; out < NUM_PORTS; ++out) {
            int winner = output_arbiters_[out].arbitrate(requests[out]);
            if (winner >= 0 && !output_busy[out]) {
                // Grant: move packet from winner's input buffer to this output.
                SpikePacket pkt = input_buffers_[winner].front();
                input_buffers_[winner].pop();
                port_out[out].write(pkt);
                output_busy[out] = true;
                packets_routed_++;
            } else {
                // No request or busy — output invalid packet.
                port_out[out].write(SpikePacket());
            }
        }
    }
};

}  // namespace nomad

#endif  // NOMAD_NOC_ROUTER_H
