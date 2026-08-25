// =============================================================================
// Module: spike_router
// Description: Inter-cluster spike delivery network.
//
//              Watches every cluster's spike output bus. When a neuron fires,
//              its GLOBAL address indexes a routing table that says which
//              cluster(s) should receive it and on which AXON. The router then
//              pulses that axon on the destination clusters.
//
// ADDRESSING
//   global address = cluster_index * NUM_NEURONS_PER_CLUSTER + local_index
//
// ROUTING TABLE (programmed by the testbench / configuration port)
//   route_valid             [g]  1 = neuron g's spikes are delivered somewhere
//   route_dest_cluster_mask [g]  bitmask of destination clusters
//   route_dest_axon         [g]  axon index within each destination cluster
//
//   One entry can fan out to several clusters, but always to the same axon
//   index in each. That is a deliberate restriction: it keeps the table one
//   word per neuron instead of one word per (neuron, cluster) pair.
//
// WHY THIS IS ALL THE INTER-CLUSTER LOGIC THAT IS NEEDED
//   A cluster already accepts externally injected spikes on
//   external_spike_input_bus, and treats such an address exactly as a
//   pre-synaptic source: it distributes that address's row of the local
//   crossbar to its own neurons and bumps that address's trace. So a
//   "remote neuron fired" event is delivered simply by pulsing the axon slot
//   that represents it. Synaptic weights and traces stay entirely inside the
//   POST-synaptic cluster, so no weight or trace data ever crosses a cluster
//   boundary -- only 1-bit spike events do.
//
//   This is the same partitioning IBM TrueNorth uses: a core owns its axons,
//   its crossbar and its neurons; the network carries spikes only.
//
// THROUGHPUT
//   One routed spike per clock. Simultaneous spikes are buffered in a FIFO and
//   drained one per cycle, so no event is lost or merged.
// =============================================================================

`timescale 1ns/1ps

module spike_router #(
    parameter NUM_CLUSTERS            = 4,
    parameter NUM_NEURONS_PER_CLUSTER = 32,
    parameter ROUTER_FIFO_DEPTH       = 64
)(
    input  wire                                                clock,
    input  wire                                                reset,
    input  wire                                                enable,

    // Spike outputs of every cluster, concatenated {cluster N-1 ... cluster 0}
    input  wire [NUM_CLUSTERS*NUM_NEURONS_PER_CLUSTER-1:0]     all_cluster_spike_bus,

    // One-cycle axon pulses back into every cluster, same concatenation
    output reg  [NUM_CLUSTERS*NUM_NEURONS_PER_CLUSTER-1:0]     axon_pulse_bus,

    output wire                                                router_busy_flag,
    output reg                                                 router_overflow_flag
);

    localparam TOTAL_NEURONS   = NUM_CLUSTERS * NUM_NEURONS_PER_CLUSTER;
    localparam LOCAL_ADDR_W    = (NUM_NEURONS_PER_CLUSTER < 2) ? 1 : $clog2(NUM_NEURONS_PER_CLUSTER);
    localparam GLOBAL_ADDR_W   = (TOTAL_NEURONS < 2) ? 1 : $clog2(TOTAL_NEURONS);
    localparam FIFO_PTR_W      = (ROUTER_FIFO_DEPTH < 2) ? 1 : $clog2(ROUTER_FIFO_DEPTH);
    localparam FIFO_CNT_W      = $clog2(ROUTER_FIFO_DEPTH + 1);

    // -------------------------------------------------------------------------
    // Routing table. Written hierarchically at configuration time.
    // -------------------------------------------------------------------------
    reg                        route_valid             [0:TOTAL_NEURONS-1];
    reg [NUM_CLUSTERS-1:0]     route_dest_cluster_mask [0:TOTAL_NEURONS-1];
    reg [LOCAL_ADDR_W-1:0]     route_dest_axon         [0:TOTAL_NEURONS-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < TOTAL_NEURONS; init_i = init_i + 1) begin
            route_valid[init_i]             = 1'b0;
            route_dest_cluster_mask[init_i] = {NUM_CLUSTERS{1'b0}};
            route_dest_axon[init_i]         = {LOCAL_ADDR_W{1'b0}};
        end
    end

    // -------------------------------------------------------------------------
    // Rising-edge detect: cluster spike outputs are one-cycle pulses already,
    // but edge detection makes the router immune to a held-high spike source.
    // -------------------------------------------------------------------------
    reg  [TOTAL_NEURONS-1:0] previous_spike_bus_register;
    wire [TOTAL_NEURONS-1:0] spike_rising_edges =
        all_cluster_spike_bus & ~previous_spike_bus_register;

    // -------------------------------------------------------------------------
    // Pending-delivery FIFO of global neuron addresses
    // -------------------------------------------------------------------------
    reg [GLOBAL_ADDR_W-1:0] pending_fifo [0:ROUTER_FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0]    fifo_head_register;
    reg [FIFO_PTR_W-1:0]    fifo_tail_register;
    reg [FIFO_CNT_W-1:0]    fifo_count_register;

    assign router_busy_flag = (fifo_count_register != 0) | (|spike_rising_edges);

    integer                 scan_i, dest_c;
    reg [FIFO_PTR_W-1:0]    tail_scratch;
    reg [FIFO_CNT_W-1:0]    count_scratch;
    reg [GLOBAL_ADDR_W-1:0] popped_address;
    reg                     popped_valid;

    always @(posedge clock) begin
        if (reset) begin
            fifo_head_register          <= {FIFO_PTR_W{1'b0}};
            fifo_tail_register          <= {FIFO_PTR_W{1'b0}};
            fifo_count_register         <= {FIFO_CNT_W{1'b0}};
            previous_spike_bus_register <= {TOTAL_NEURONS{1'b0}};
            axon_pulse_bus              <= {TOTAL_NEURONS{1'b0}};
            router_overflow_flag        <= 1'b0;
        end else begin
            previous_spike_bus_register <= all_cluster_spike_bus;
            axon_pulse_bus              <= {TOTAL_NEURONS{1'b0}};   // one-cycle pulses

            tail_scratch  = fifo_tail_register;
            count_scratch = fifo_count_register;
            popped_valid  = 1'b0;
            popped_address = {GLOBAL_ADDR_W{1'b0}};

            if (enable) begin
                // ---- deliver one pending spike ----
                if (count_scratch != 0) begin
                    popped_address     = pending_fifo[fifo_head_register];
                    popped_valid       = 1'b1;
                    fifo_head_register <= (fifo_head_register + 1'b1) % ROUTER_FIFO_DEPTH;
                    count_scratch      = count_scratch - 1'b1;
                end

                // ---- accept new spikes ----
                if (|spike_rising_edges) begin
                    for (scan_i = 0; scan_i < TOTAL_NEURONS; scan_i = scan_i + 1) begin
                        if (spike_rising_edges[scan_i] && route_valid[scan_i]) begin
                            if (count_scratch < ROUTER_FIFO_DEPTH) begin
                                pending_fifo[tail_scratch] <= scan_i[GLOBAL_ADDR_W-1:0];
                                tail_scratch  = (tail_scratch + 1'b1) % ROUTER_FIFO_DEPTH;
                                count_scratch = count_scratch + 1'b1;
                            end else begin
                                router_overflow_flag <= 1'b1;
                            end
                        end
                    end
                end

                // ---- drive the destination axons for the popped spike ----
                if (popped_valid) begin
                    for (dest_c = 0; dest_c < NUM_CLUSTERS; dest_c = dest_c + 1) begin
                        if (route_dest_cluster_mask[popped_address][dest_c]) begin
                            axon_pulse_bus[dest_c*NUM_NEURONS_PER_CLUSTER +
                                           route_dest_axon[popped_address]] <= 1'b1;
                        end
                    end
                end
            end

            fifo_tail_register  <= tail_scratch;
            fifo_count_register <= count_scratch;
        end
    end

endmodule
