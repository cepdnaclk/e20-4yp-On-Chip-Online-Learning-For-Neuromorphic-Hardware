#ifndef NOMAD_NOC_NOC_MESH_H
#define NOMAD_NOC_NOC_MESH_H

#include "noc/router.h"
#include <vector>
#include <memory>
#include <iostream>

namespace nomad {

/// @brief 2D Mesh NOC topology builder.
///
/// Creates a grid of Router modules and wires their directional ports
/// together. After construction, signals written to one router's output
/// automatically propagate to the neighbour's input (via Signal listeners).
///
/// Example (3×3 mesh):
/// @code
///   NocMesh mesh("mesh", 3, 3);
///   mesh.initialize();
///   // Inject packet at router (0,0) local port:
///   mesh.router(0,0).port_in[0].write(pkt);
///   // Advance clock:
///   mesh.tick();
/// @endcode
///
class NocMesh : public Module {
public:
    /// @param name  Module name.
    /// @param width  Number of columns (X dimension).
    /// @param height Number of rows (Y dimension).
    /// @param buf_depth  Per-port buffer depth for each router.
    NocMesh(const std::string& name, int width, int height, int buf_depth = 4)
        : Module(name), width_(width), height_(height)
    {
        // Create all routers.
        routers_.resize(width * height);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                std::string rname = "router_" + std::to_string(x) + "_" + std::to_string(y);
                routers_[index(x, y)] = std::make_unique<Router>(
                    rname, static_cast<uint8_t>(x), static_cast<uint8_t>(y), buf_depth);
                add_child(routers_[index(x, y)].get());
            }
        }

        // Wire neighbours together.
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                Router& r = *routers_[index(x, y)];

                // North: connect r.port_out[North] → neighbour(x, y-1).port_in[South]
                if (y > 0) {
                    connect_ports(
                        r.port_out[static_cast<int>(Direction::North)],
                        routers_[index(x, y - 1)]->port_in[static_cast<int>(Direction::South)]
                    );
                }

                // South
                if (y < height - 1) {
                    connect_ports(
                        r.port_out[static_cast<int>(Direction::South)],
                        routers_[index(x, y + 1)]->port_in[static_cast<int>(Direction::North)]
                    );
                }

                // East
                if (x < width - 1) {
                    connect_ports(
                        r.port_out[static_cast<int>(Direction::East)],
                        routers_[index(x + 1, y)]->port_in[static_cast<int>(Direction::West)]
                    );
                }

                // West
                if (x > 0) {
                    connect_ports(
                        r.port_out[static_cast<int>(Direction::West)],
                        routers_[index(x - 1, y)]->port_in[static_cast<int>(Direction::East)]
                    );
                }
            }
        }
    }

    void process() override {
        // NocMesh itself doesn't do logic; routers handle everything.
    }

    void initialize() override {
        for (auto& r : routers_) {
            r->initialize();
        }
    }

    /// Advance all routers by one clock cycle.
    void tick() {
        for (auto& r : routers_) {
            r->clk.write(true);
        }
        for (auto& r : routers_) {
            r->clk.write(false);
        }
    }

    // ── Accessors ─────────────────────────────────────────

    int width() const { return width_; }
    int height() const { return height_; }

    /// Access a router by coordinate.
    Router& router(int x, int y) { return *routers_[index(x, y)]; }
    const Router& router(int x, int y) const { return *routers_[index(x, y)]; }

    /// Total packets routed across all routers.
    uint32_t total_packets_routed() const {
        uint32_t total = 0;
        for (const auto& r : routers_) total += r->packets_routed();
        return total;
    }

    /// Print network status.
    void print_status() const {
        std::cout << "NocMesh[" << name() << "] " << width_ << "x" << height_ << ":\n";
        for (int y = 0; y < height_; ++y) {
            for (int x = 0; x < width_; ++x) {
                const auto& r = *routers_[index(x, y)];
                std::cout << "  (" << x << "," << y << ") routed="
                          << r.packets_routed() << " buf=" << r.buffered_count() << "\n";
            }
        }
    }

private:
    int width_;
    int height_;
    std::vector<std::unique_ptr<Router>> routers_;

    int index(int x, int y) const { return y * width_ + x; }

    /// Connect an output signal to an input signal:
    /// when out changes, copy its value to in.
    void connect_ports(Signal<SpikePacket>& out, Signal<SpikePacket>& in) {
        out.add_listener([&out, &in]() {
            in.write(out.read());
        });
    }
};

}  // namespace nomad

#endif  // NOMAD_NOC_NOC_MESH_H
