// =============================================================================
// Module: neuron_cluster_array
// Description: Multi-cluster top level. NUM_CLUSTERS instances of
//              neuron_cluster plus one spike_router.
//
//   Total neurons = NUM_CLUSTERS * NUM_NEURONS_PER_CLUSTER
//   e.g. 32 clusters x 32 neurons = 1024 neurons
//
// PARTITIONING
//   Each cluster owns its axons, its crossbar, its weight banks, its traces
//   and its neurons. Nothing but 1-bit spike events crosses a cluster
//   boundary, so weight and trace memory never has to be shared or coherent.
//
//   Within a cluster the local address space is split by convention (the
//   testbench decides, nothing here is hardwired):
//       addresses used as AXONS   - driven by the router or by external input,
//                                   act purely as pre-synaptic sources
//       addresses used as NEURONS - real LIF neurons whose spikes leave the
//                                   cluster through the router
//
//   An axon slot still instantiates a LIF neuron, which simply never fires
//   because nothing is wired into it. That costs area but keeps neuron_cluster
//   completely unmodified.
//
// SPIKE PATH
//   cluster k neuron fires
//     -> cluster_spike_output_bus[k]
//     -> spike_router  (routing table lookup: destination clusters + axon)
//     -> external_spike_input_bus of each destination cluster
//     -> that cluster distributes the axon's weight row to its own neurons
//        and bumps the axon's pre-synaptic trace
//
// LIMITATIONS (documented, not accidental)
//   * Winner-take-all is per cluster. There is no global WTA across clusters.
//   * A routing entry fans out to several clusters but always to the same axon
//     index in each.
//   * Fan-in per neuron is bounded by NUM_NEURONS_PER_CLUSTER, because the
//     crossbar is NUM_NEURONS_PER_CLUSTER axons wide.
// =============================================================================

`timescale 1ns/1ps

module neuron_cluster_array #(
    parameter NUM_CLUSTERS                 = 4,
    parameter NUM_NEURONS_PER_CLUSTER      = 32,
    parameter ROUTER_FIFO_DEPTH            = 64,

    // ---- forwarded to every neuron_cluster ----
    parameter WEIGHT_BIT_WIDTH             = 8,
    parameter TRACE_VALUE_BIT_WIDTH        = 8,
    parameter DECAY_TIMER_BIT_WIDTH        = 12,
    parameter TRACE_SATURATION_THRESHOLD   = 256,
    parameter DECAY_SHIFT_LOG2             = 0,
    parameter TRACE_INCREMENT_VALUE        = 32,
    parameter NUM_TRACE_UPDATE_MODULES     = 4,
    parameter LTP_SHIFT_AMOUNT             = 3,
    parameter LTD_SHIFT_AMOUNT             = 5,
    parameter INCREASE_MODE                = 0,
    parameter MEMBRANE_BIT_WIDTH           = 20,
    parameter BASE_THRESHOLD               = 1500,
    parameter MEMBRANE_LEAK_SHIFT          = 4,
    parameter REFRACTORY_CYCLES            = 8,
    parameter THETA_INCREMENT              = 1200,
    parameter THETA_DECAY_SHIFT            = 7,

    // Per-layer excitability override.
    //
    // Clusters with index >= CLUSTER_SPLIT_INDEX use the _UPPER values. A
    // deeper layer sees far sparser input than the layer feeding it -- in the
    // two-layer MNIST topology layer 1 receives ~3.3 spikes/timestep while
    // layer 2 receives ~1.5 -- so a single array-wide threshold either starves
    // the deeper layer or saturates the shallower one. Default leaves the
    // split off (index == NUM_CLUSTERS), so every cluster uses the base values.
    parameter CLUSTER_SPLIT_INDEX          = NUM_CLUSTERS,
    parameter BASE_THRESHOLD_UPPER         = BASE_THRESHOLD,
    parameter THETA_INCREMENT_UPPER        = THETA_INCREMENT,

    // WTA group, expressed as local addresses inside every cluster
    parameter WTA_GROUP_START              = 0,
    parameter WTA_GROUP_END                = 0,
    parameter WTA_ENABLE                   = 0,
    parameter WTA_INHIBIT_CYCLES           = 8
)(
    input  wire                                            clock,
    input  wire                                            reset,
    input  wire                                            global_cluster_enable,
    input  wire                                            learning_enable,
    input  wire                                            adaptation_enable,
    input  wire                                            membrane_clear,
    input  wire                                            decay_enable_pulse,
    input  wire                                            router_enable,

    // Externally injected spikes, {cluster N-1 ... cluster 0}
    input  wire [NUM_CLUSTERS*NUM_NEURONS_PER_CLUSTER-1:0] external_spike_input_bus,

    // Neuron spikes from every cluster, same concatenation
    output wire [NUM_CLUSTERS*NUM_NEURONS_PER_CLUSTER-1:0] cluster_spike_output_bus,

    output wire                                            array_busy_flag,
    output wire                                            queue_overflow_flag,
    output wire                                            transaction_timeout_flag,
    output wire                                            router_overflow_flag
);

    localparam N                = NUM_NEURONS_PER_CLUSTER;
    localparam NEURON_ADDR_W    = (N < 2) ? 1 : $clog2(N);

    wire [NUM_CLUSTERS*N-1:0] router_axon_pulse_bus;
    wire [NUM_CLUSTERS*N-1:0] cluster_input_bus;

    wire [NUM_CLUSTERS-1:0]   cluster_busy;
    wire [NUM_CLUSTERS-1:0]   cluster_queue_overflow;
    wire [NUM_CLUSTERS-1:0]   cluster_txn_timeout;
    wire                      router_busy;

    // A cluster's stimulus is whatever the router delivers, OR whatever the
    // testbench injects directly.
    assign cluster_input_bus = router_axon_pulse_bus | external_spike_input_bus;

    assign array_busy_flag          = (|cluster_busy) | router_busy;
    assign queue_overflow_flag      = |cluster_queue_overflow;
    assign transaction_timeout_flag = |cluster_txn_timeout;

    // =========================================================================
    // Clusters
    // =========================================================================
    genvar c;
    generate
        for (c = 0; c < NUM_CLUSTERS; c = c + 1) begin : gen_clusters
            neuron_cluster #(
                .NUM_NEURONS_PER_CLUSTER    (N),
                .NEURON_ADDRESS_WIDTH       (NEURON_ADDR_W),
                .NUM_WEIGHT_BANKS           (N),
                .WEIGHT_BANK_ADDRESS_WIDTH  (NEURON_ADDR_W),
                .WEIGHT_BIT_WIDTH           (WEIGHT_BIT_WIDTH),
                .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
                .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
                .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
                .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
                .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
                .NUM_TRACE_UPDATE_MODULES   (NUM_TRACE_UPDATE_MODULES),
                .SPIKE_QUEUE_DEPTH          (N),
                .LTP_SHIFT_AMOUNT           (LTP_SHIFT_AMOUNT),
                .LTD_SHIFT_AMOUNT           (LTD_SHIFT_AMOUNT),
                .INCREASE_MODE              (INCREASE_MODE),
                .MEMBRANE_BIT_WIDTH         (MEMBRANE_BIT_WIDTH),
                .BASE_THRESHOLD             ((c >= CLUSTER_SPLIT_INDEX) ?
                                             BASE_THRESHOLD_UPPER : BASE_THRESHOLD),
                .MEMBRANE_LEAK_SHIFT        (MEMBRANE_LEAK_SHIFT),
                .REFRACTORY_CYCLES          (REFRACTORY_CYCLES),
                .THETA_INCREMENT            ((c >= CLUSTER_SPLIT_INDEX) ?
                                             THETA_INCREMENT_UPPER : THETA_INCREMENT),
                .THETA_DECAY_SHIFT          (THETA_DECAY_SHIFT),
                .WTA_GROUP_START            (WTA_GROUP_START),
                .WTA_GROUP_END              (WTA_GROUP_END),
                .WTA_ENABLE                 (WTA_ENABLE),
                .WTA_INHIBIT_CYCLES         (WTA_INHIBIT_CYCLES)
            ) cluster_inst (
                .clock                    (clock),
                .reset                    (reset),
                .global_cluster_enable    (global_cluster_enable),
                .learning_enable          (learning_enable),
                .adaptation_enable        (adaptation_enable),
                .membrane_clear           (membrane_clear),
                .decay_enable_pulse       (decay_enable_pulse),
                .external_spike_input_bus (cluster_input_bus       [c*N +: N]),
                .cluster_spike_output_bus (cluster_spike_output_bus[c*N +: N]),
                .cluster_busy_flag        (cluster_busy[c]),
                .queue_overflow_flag      (cluster_queue_overflow[c]),
                .transaction_timeout_flag (cluster_txn_timeout[c])
            );
        end
    endgenerate

    // =========================================================================
    // Inter-cluster router
    // =========================================================================
    spike_router #(
        .NUM_CLUSTERS            (NUM_CLUSTERS),
        .NUM_NEURONS_PER_CLUSTER (N),
        .ROUTER_FIFO_DEPTH       (ROUTER_FIFO_DEPTH)
    ) router_inst (
        .clock                 (clock),
        .reset                 (reset),
        .enable                (router_enable),
        .all_cluster_spike_bus (cluster_spike_output_bus),
        .axon_pulse_bus        (router_axon_pulse_bus),
        .router_busy_flag      (router_busy),
        .router_overflow_flag  (router_overflow_flag)
    );

endmodule
