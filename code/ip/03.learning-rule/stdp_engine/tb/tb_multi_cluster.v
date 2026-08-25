// =============================================================================
// Testbench: tb_multi_cluster
// Directed tests for the multi-cluster architecture.
//
// Topology under test: NUM_CLUSTERS clusters of NUM_NEURONS_PER_CLUSTER,
// wired as a feedforward chain
//
//     external -> C0.axonA -> C0.neuron -> C1.axonA -> C1.neuron -> ...
//
// Each cluster uses local address AXON_A as its routed input axon, AXON_B as a
// second (deliberately silent) axon, and NEURON_A as its output neuron. The
// router carries a spike from one cluster's neuron to the next cluster's axon.
//
// Verified here:
//   1  a spike injected into cluster 0 makes cluster 0's neuron fire
//   2  the router delivers that spike across a cluster boundary
//   3  the chain propagates through every cluster in order
//   4  a cluster with no outgoing route does not drive anything
//   5  the router serialises simultaneous spikes instead of merging them
//   6  STDP runs on a CROSS-CLUSTER synapse: LTP raises a weight in the
//      downstream cluster when its routed axon fires just before its neuron
//   7  LTD lowers a weight whose axon stayed silent
//   8  no queue overflow, transaction timeout or router overflow anywhere
//
// REQUIRES NUM_CLUSTERS >= 2. Group 4 reads weights out of cluster 1 to prove
// a synapse was trained by a spike that crossed a boundary, which is only
// meaningful with more than one cluster. The single-cluster path is covered by
// `make mnist` and the per-module unit tests.
//
// NOTE on hierarchical configuration: Icarus cannot index a generate scope
// with a runtime variable, so per-cluster setup lives in a generate block
// where the cluster index is a genvar (a constant inside each instance).
// The main stimulus process releases it with cfg_go.
// =============================================================================

`timescale 1ns/1ps

module tb_multi_cluster;

    parameter NUM_CLUSTERS            = 4;
    parameter NUM_NEURONS_PER_CLUSTER = 32;
    parameter N                       = NUM_NEURONS_PER_CLUSTER;
    parameter TOTAL_NEURONS           = NUM_CLUSTERS * N;
    parameter LOCAL_W                 = 5;   // $clog2(32)

    // local address map inside every cluster
    parameter AXON_A   = 0;    // fed by the router / external input
    parameter AXON_B   = 1;    // second axon, kept silent for the LTD check
    parameter NEURON_A = 16;   // the real spiking neuron

    parameter CLK_PERIOD = 10;
    parameter W_STRONG   = 8'd250;   // one axon spike is enough to fire a neuron
    parameter W_MID      = 8'd120;   // mid-range so LTD has room to move

    reg clock = 0;
    reg reset, gce, learn_en, adapt_en, mclear, decay_pulse, router_en;
    reg [TOTAL_NEURONS-1:0] ext_in;

    wire [TOTAL_NEURONS-1:0] spikes;
    wire busy, q_ovf, txn_to, rtr_ovf;

    neuron_cluster_array #(
        .NUM_CLUSTERS             (NUM_CLUSTERS),
        .NUM_NEURONS_PER_CLUSTER  (N),
        .ROUTER_FIFO_DEPTH        (64),
        .DECAY_SHIFT_LOG2         (0),
        .NUM_TRACE_UPDATE_MODULES (4),
        .LTP_SHIFT_AMOUNT         (3),
        .LTD_SHIFT_AMOUNT         (5),
        .BASE_THRESHOLD           (200),
        .MEMBRANE_LEAK_SHIFT      (4),
        .THETA_INCREMENT          (0),      // homeostasis off: directed test
        .THETA_DECAY_SHIFT        (7),
        .REFRACTORY_CYCLES        (4),
        .WTA_ENABLE               (0)       // no WTA: deterministic firing
    ) uut (
        .clock                    (clock),
        .reset                    (reset),
        .global_cluster_enable    (gce),
        .learning_enable          (learn_en),
        .adaptation_enable        (adapt_en),
        .membrane_clear           (mclear),
        .decay_enable_pulse       (decay_pulse),
        .router_enable            (router_en),
        .external_spike_input_bus (ext_in),
        .cluster_spike_output_bus (spikes),
        .array_busy_flag          (busy),
        .queue_overflow_flag      (q_ovf),
        .transaction_timeout_flag (txn_to),
        .router_overflow_flag     (rtr_ovf)
    );

    always #(CLK_PERIOD/2) clock = ~clock;

    // bank holding W(pre -> post):  bank_memory[(post + pre) mod N][post]
    function integer bank_of;
        input integer pre;
        input integer post;
        begin bank_of = (post + pre) % N; end
    endfunction

    // =========================================================================
    // Per-cluster configuration (genvar so the scope index is constant)
    // =========================================================================
    reg cfg_go = 1'b0;

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CLUSTERS; gc = gc + 1) begin : cfgblk
            initial begin
                wait (cfg_go === 1'b1);
                // crossbar: both axons drive the neuron
                uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                    .output_connection_rows[AXON_A][NEURON_A] = 1'b1;
                uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                    .input_connection_rows [NEURON_A][AXON_A] = 1'b1;
                uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                    .output_connection_rows[AXON_B][NEURON_A] = 1'b1;
                uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                    .input_connection_rows [NEURON_A][AXON_B] = 1'b1;
                // weights
                uut.gen_clusters[gc].cluster_inst.weight_memory_inst
                    .bank_memory[(NEURON_A + AXON_A) % N][NEURON_A] = W_STRONG;
                uut.gen_clusters[gc].cluster_inst.weight_memory_inst
                    .bank_memory[(NEURON_A + AXON_B) % N][NEURON_A] = W_MID;
            end
        end
    endgenerate

    // =========================================================================
    // Live per-neuron spike counters
    // =========================================================================
    integer spike_count [0:TOTAL_NEURONS-1];
    integer sc_i;
    reg     count_en;
    always @(posedge clock)
        if (count_en)
            for (sc_i = 0; sc_i < TOTAL_NEURONS; sc_i = sc_i + 1)
                if (spikes[sc_i]) spike_count[sc_i] = spike_count[sc_i] + 1;

    // =========================================================================
    // Scoreboard
    // =========================================================================
    integer pass_count = 0, fail_count = 0;

    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    task check_idx;                       // name with a cluster index
        input [511:0] name;
        input integer idx;
        input         cond;
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("  [PASS] C%0d %0s", idx, name);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] C%0d %0s", idx, name);
            end
        end
    endtask

    task check_eq_idx;
        input [511:0] name;
        input integer idx;
        input integer got;
        input integer want;
        begin
            if (got == want) begin
                pass_count = pass_count + 1;
                $display("  [PASS] C%0d %0s (%0d)", idx, name, got);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] C%0d %0s: got %0d, expected %0d",
                         idx, name, got, want);
            end
        end
    endtask

    // =========================================================================
    // Helpers
    // =========================================================================
    integer c, g, guard, t;
    integer others;

    task clear_counts;
        begin
            for (sc_i = 0; sc_i < TOTAL_NEURONS; sc_i = sc_i + 1) spike_count[sc_i] = 0;
        end
    endtask

    task settle;
        begin
            guard = 0;
            while (busy && guard < 20000) begin @(posedge clock); guard = guard + 1; end
            repeat (20) @(posedge clock);
            #1;
        end
    endtask

    task inject;
        input integer cluster;
        input integer local_addr;
        begin
            ext_in = {TOTAL_NEURONS{1'b0}};
            ext_in[cluster*N + local_addr] = 1'b1;
            @(posedge clock); #1;
            ext_in = {TOTAL_NEURONS{1'b0}};
        end
    endtask

    task decay_tick;
        input integer ticks;
        begin
            for (t = 0; t < ticks; t = t + 1) begin
                decay_pulse = 1; @(posedge clock); #1;
                decay_pulse = 0; @(posedge clock); #1;
            end
        end
    endtask

    integer w_before, w_after, wb_before, wb_after;

    // =========================================================================
    initial begin
        $display("================================================================");
        $display("  MULTI-CLUSTER ARCHITECTURE TEST");
        $display("  %0d clusters x %0d neurons = %0d neurons total",
                 NUM_CLUSTERS, N, TOTAL_NEURONS);
        $display("  chain: ext -> C0.axon%0d -> C0.n%0d -> C1.axon%0d -> ...",
                 AXON_A, NEURON_A, AXON_A);
        $display("================================================================");

        reset = 1; gce = 0; learn_en = 0; adapt_en = 0;
        mclear = 0; decay_pulse = 0; router_en = 0;
        ext_in = {TOTAL_NEURONS{1'b0}};
        count_en = 0;
        clear_counts();
        repeat (6) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // release the per-cluster configuration processes
        cfg_go = 1'b1;
        #1;

        // routing table: cluster c's neuron -> cluster c+1's axon A
        for (c = 0; c < NUM_CLUSTERS - 1; c = c + 1) begin
            g = c*N + NEURON_A;
            uut.router_inst.route_valid[g]             = 1'b1;
            uut.router_inst.route_dest_cluster_mask[g] = (1 << (c+1));
            uut.router_inst.route_dest_axon[g]         = AXON_A[LOCAL_W-1:0];
        end
        @(posedge clock); #1;

        gce = 1; router_en = 1; count_en = 1;
        repeat (2) @(posedge clock); #1;

        // ==================================================================
        $display("");
        $display("--- Group 1: cross-cluster spike propagation ---");
        clear_counts();
        inject(0, AXON_A);
        settle();

        check_eq_idx("neuron fired from external injection", 0,
                     spike_count[0*N + NEURON_A], 1);
        for (c = 1; c < NUM_CLUSTERS; c = c + 1)
            check_eq_idx("neuron fired via router (crossed a cluster boundary)", c,
                         spike_count[c*N + NEURON_A], 1);

        // ==================================================================
        $display("");
        $display("--- Group 2: a cluster with no outgoing route drives nothing ---");
        clear_counts();
        inject(NUM_CLUSTERS-1, AXON_A);
        settle();
        check_eq_idx("neuron fired from its own injection", NUM_CLUSTERS-1,
                     spike_count[(NUM_CLUSTERS-1)*N + NEURON_A], 1);
        others = 0;
        for (c = 0; c < NUM_CLUSTERS-1; c = c + 1)
            others = others + spike_count[c*N + NEURON_A];
        check_eq_idx("no upstream cluster fired", NUM_CLUSTERS-1, others, 0);

        // ==================================================================
        $display("");
        $display("--- Group 3: router serialises simultaneous spikes ---");
        clear_counts();
        ext_in = {TOTAL_NEURONS{1'b0}};
        for (c = 0; c < NUM_CLUSTERS; c = c + 1) ext_in[c*N + AXON_A] = 1'b1;
        @(posedge clock); #1;
        ext_in = {TOTAL_NEURONS{1'b0}};
        settle();
        for (c = 0; c < NUM_CLUSTERS; c = c + 1)
            check_idx("neuron fired on simultaneous injection", c,
                      spike_count[c*N + NEURON_A] >= 1);
        check("router reported no overflow", rtr_ovf === 1'b0);

        // ==================================================================
        $display("");
        $display("--- Group 4: STDP on a CROSS-CLUSTER synapse ---");
        // Cluster 1's axon A is fed only by cluster 0's neuron, so any weight
        // change on W(axonA -> neuronA) inside cluster 1 is caused entirely by
        // a spike that crossed a cluster boundary.
        decay_tick(16);
        settle();

        w_before  = uut.gen_clusters[1].cluster_inst.weight_memory_inst
                      .bank_memory[(NEURON_A + AXON_A) % N][NEURON_A];
        wb_before = uut.gen_clusters[1].cluster_inst.weight_memory_inst
                      .bank_memory[(NEURON_A + AXON_B) % N][NEURON_A];

        learn_en = 1;
        clear_counts();
        inject(0, AXON_A);          // C0 fires -> router -> C1.axonA -> C1 neuron
        settle();
        learn_en = 0;

        w_after  = uut.gen_clusters[1].cluster_inst.weight_memory_inst
                     .bank_memory[(NEURON_A + AXON_A) % N][NEURON_A];
        wb_after = uut.gen_clusters[1].cluster_inst.weight_memory_inst
                     .bank_memory[(NEURON_A + AXON_B) % N][NEURON_A];

        $display("    C1  W(axonA->n) %0d -> %0d      W(axonB->n) %0d -> %0d",
                 w_before, w_after, wb_before, wb_after);

        check_idx("neuron fired from the routed spike", 1,
                  spike_count[1*N + NEURON_A] >= 1);
        check("LTP: cross-cluster active synapse potentiated", w_after > w_before);
        check("LTD: silent synapse in the same cluster depressed", wb_after < wb_before);

        // ==================================================================
        $display("");
        $display("--- Group 5: health flags ---");
        check("no queue overflow in any cluster", q_ovf === 1'b0);
        check("no STDP transaction timeout",      txn_to === 1'b0);
        check("no router overflow",               rtr_ovf === 1'b0);

        // ==================================================================
        $display("");
        $display("================================================================");
        $display("  RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL MULTI-CLUSTER TESTS PASSED");
        else
            $display("  *** %0d FAILURE(S) ***", fail_count);
        $display("================================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000000);
        $display("  [WATCHDOG] simulation did not finish");
        $finish;
    end

endmodule
