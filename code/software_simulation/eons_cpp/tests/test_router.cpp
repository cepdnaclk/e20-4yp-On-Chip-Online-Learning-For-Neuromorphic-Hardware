/// @file test_router.cpp
/// @brief Unit tests for Router, Arbiter, and NocMesh.
///
/// Run: ./build/test_router

#include "noc/noc_mesh.h"
#include "noc/router.h"
#include "noc/arbiter.h"
#include "neuro/spike_packet.h"
#include "core/fixed_point.h"
#include <cassert>
#include <iostream>

using namespace nomad;

// ── Helpers ───────────────────────────────────────────────────

void tick_router(Router& r) {
    r.clk.write(true);
    r.clk.write(false);
}

// ── Tests ─────────────────────────────────────────────────────

void test_arbiter_basic() {
    std::cout << "  test_arbiter_basic ... ";
    Arbiter<5> arb;

    // Only port 2 requesting
    std::array<bool, 5> req = {false, false, true, false, false};
    int winner = arb.arbitrate(req);
    assert(winner == 2);

    // Ports 2 and 3 requesting — round robin should pick 3 next
    req = {false, false, true, true, false};
    winner = arb.arbitrate(req);
    assert(winner == 3);

    // Again — should rotate back to 2
    winner = arb.arbitrate(req);
    assert(winner == 2);
    std::cout << "PASS\n";
}

void test_arbiter_no_requests() {
    std::cout << "  test_arbiter_no_requests ... ";
    Arbiter<5> arb;
    std::array<bool, 5> req = {false, false, false, false, false};
    int winner = arb.arbitrate(req);
    assert(winner == -1);
    std::cout << "PASS\n";
}

void test_router_xy_local_delivery() {
    std::cout << "  test_router_xy_local_delivery ... ";
    // Router at (1,1) — packet destined for (1,1) should go to Local port.
    Router r("r_1_1", 1, 1);
    r.initialize();

    SpikePacket pkt(0, 0, 1, 1, 5, fp16_8::from_float(0.5f));
    r.port_in[static_cast<int>(Direction::West)].write(pkt);
    tick_router(r);

    // Packet should appear on Local output.
    SpikePacket out = r.port_out[static_cast<int>(Direction::Local)].read();
    assert(out.valid == true);
    assert(out.dst_x == 1 && out.dst_y == 1);
    assert(out.neuron_id == 5);
    std::cout << "PASS\n";
}

void test_router_xy_east() {
    std::cout << "  test_router_xy_east ... ";
    // Router at (0,0) — packet destined for (2,0) should go East.
    Router r("r_0_0", 0, 0);
    r.initialize();

    SpikePacket pkt(0, 0, 2, 0, 3, fp16_8::from_float(1.0f));
    r.port_in[static_cast<int>(Direction::Local)].write(pkt);
    tick_router(r);

    SpikePacket out = r.port_out[static_cast<int>(Direction::East)].read();
    assert(out.valid == true);
    assert(out.dst_x == 2);
    std::cout << "PASS\n";
}

void test_router_xy_south() {
    std::cout << "  test_router_xy_south ... ";
    // Router at (1,0) — packet destined for (1,2) should go South.
    Router r("r_1_0", 1, 0);
    r.initialize();

    SpikePacket pkt(0, 0, 1, 2, 0, fp16_8::from_float(0.3f));
    r.port_in[static_cast<int>(Direction::Local)].write(pkt);
    tick_router(r);

    SpikePacket out = r.port_out[static_cast<int>(Direction::South)].read();
    assert(out.valid == true);
    assert(out.dst_y == 2);
    std::cout << "PASS\n";
}

void test_mesh_construction() {
    std::cout << "  test_mesh_construction ... ";
    NocMesh mesh("mesh", 3, 3);
    mesh.initialize();

    assert(mesh.width() == 3);
    assert(mesh.height() == 3);
    assert(mesh.router(0, 0).pos_x() == 0);
    assert(mesh.router(2, 2).pos_x() == 2);
    assert(mesh.router(2, 2).pos_y() == 2);
    std::cout << "PASS\n";
}

void test_mesh_end_to_end() {
    std::cout << "  test_mesh_end_to_end ... ";
    // 3×3 mesh: inject packet at (0,0) destined for (2,0).
    // XY routing: (0,0) → East → (1,0) → East → (2,0) → Local
    // Should take 3 ticks to arrive (one hop per tick).
    NocMesh mesh("mesh_e2e", 3, 1);  // 3×1 for simplicity
    mesh.initialize();

    SpikePacket pkt(0, 0, 2, 0, 7, fp16_8::from_float(0.9f));

    // Inject at router(0,0) local input.
    mesh.router(0, 0).port_in[static_cast<int>(Direction::Local)].write(pkt);

    // Tick 1: packet should move from (0,0) to (1,0) via East.
    mesh.tick();

    // Tick 2: packet should move from (1,0) to (2,0) via East.
    mesh.tick();

    // Tick 3: packet should be delivered to (2,0) Local output.
    mesh.tick();

    SpikePacket delivered = mesh.router(2, 0).port_out[static_cast<int>(Direction::Local)].read();
    assert(delivered.valid == true);
    assert(delivered.dst_x == 2 && delivered.dst_y == 0);
    assert(delivered.neuron_id == 7);

    assert(mesh.total_packets_routed() >= 3);  // at least 3 hops
    std::cout << "PASS\n";
}

// ── Main ──────────────────────────────────────────────────────

int main() {
    std::cout << "=== Router & NOC Tests ===\n";
    test_arbiter_basic();
    test_arbiter_no_requests();
    test_router_xy_local_delivery();
    test_router_xy_east();
    test_router_xy_south();
    test_mesh_construction();
    test_mesh_end_to_end();
    std::cout << "=== All Router & NOC tests passed ===\n";
    return 0;
}
