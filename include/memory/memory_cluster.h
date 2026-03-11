#ifndef NOMAD_MEMORY_MEMORY_CLUSTER_H
#define NOMAD_MEMORY_MEMORY_CLUSTER_H

#include "core/module.h"
#include "core/signal.h"
#include "core/fixed_point.h"
#include <vector>
#include <cstdint>
#include <iostream>

namespace nomad {

/// @brief Addressable RAM block with signal-based ports.
///
/// Models a hardware memory block used to store synaptic weights,
/// neuron parameters, and connectivity maps. Access is through
/// address/data signals, mimicking a Verilog memory module.
///
/// Ports:
///   - clk          : Clock signal (read/write on posedge)
///   - write_en     : Write enable
///   - addr         : Address bus
///   - data_in      : Data input (for writes)
///   - data_out     : Data output (for reads, updated on posedge after addr change)
///
class MemoryCluster : public Module {
public:
    // ── Ports ─────────────────────────────────────────────────
    Signal<bool>     clk{"mem_clk"};
    Signal<bool>     write_en{"mem_we"};
    Signal<uint16_t> addr{"mem_addr"};
    Signal<int32_t>  data_in{"mem_din"};
    Signal<int32_t>  data_out{"mem_dout"};

    /// @param name   Module instance name.
    /// @param depth  Number of addressable locations.
    MemoryCluster(const std::string& name, uint16_t depth)
        : Module(name), depth_(depth), mem_(depth, 0)
    {
        sensitive_to(clk);
    }

    /// Process on clock posedge: perform read or write.
    void process() override {
        if (!clk.posedge()) return;

        uint16_t a = addr.read();
        if (a >= depth_) return;  // out-of-bounds guard

        if (write_en.read()) {
            // Write operation
            mem_[a] = data_in.read();
        } else {
            // Read operation — drive data_out
            data_out.write(mem_[a]);
        }
    }

    // ── Direct access (for initialisation and testing) ────────

    /// Read a value directly (bypassing signals).
    int32_t direct_read(uint16_t address) const {
        if (address >= depth_) return 0;
        return mem_[address];
    }

    /// Write a value directly (bypassing signals).
    void direct_write(uint16_t address, int32_t value) {
        if (address < depth_) {
            mem_[address] = value;
        }
    }

    /// Get the memory depth.
    uint16_t depth() const { return depth_; }

    /// Clear all memory to zero.
    void clear() {
        std::fill(mem_.begin(), mem_.end(), 0);
    }

    /// Dump memory contents (for debugging).
    void dump(uint16_t start = 0, uint16_t count = 16) const {
        std::cout << "MemoryCluster[" << name() << "] dump:\n";
        for (uint16_t i = start; i < start + count && i < depth_; ++i) {
            std::cout << "  [" << i << "] = " << mem_[i] << "\n";
        }
    }

private:
    uint16_t depth_;
    std::vector<int32_t> mem_;
};

}  // namespace nomad

#endif  // NOMAD_MEMORY_MEMORY_CLUSTER_H
