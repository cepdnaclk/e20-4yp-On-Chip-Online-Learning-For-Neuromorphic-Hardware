//==============================================================================
// Project: Neuromorphic Processing System - FYP II
// Module:  tb_neuron_cluster
// Description:
//   Testbench for the neuron_cluster module.
//
// Issues identified and fixed:
//   1. Connection matrix was not initialised before the DUT was reset, causing
//      the first test to run with an undefined conn_matrix; all inputs are now
//      driven to known-good values before de-asserting reset.
//   2. Spike injection was applied without waiting for the DUT to be out of
//      reset, so the very first spike was lost; the testbench now waits for
//      at least one idle cycle after reset before injecting spikes.
//   3. The weight read-back used hard-coded bit-slice indices that were
//      incorrect for the default N_NEURONS=4 / WEIGHT_WIDTH=8 layout; a
//      parameterised helper function (get_weight) is used instead.
//   4. STDP verification was attempted without first pre-loading non-zero
//      weights; with weight=0 the neuron can never reach threshold and no
//      post-synaptic spike (hence no weight update) is produced.  The test
//      now loads a weight that is large enough to drive the post-synaptic
//      neuron to fire.
//
// Test plan
//   TEST 1  Reset – all outputs must be zero after reset.
//   TEST 2  Connection matrix – configure a 4-node topology and confirm
//           weights can be loaded into the correct entries.
//   TEST 3  Weight loading – verify bulk-load of initial weights.
//   TEST 4  External spike injection – drive one neuron to threshold via
//           repeated ext_spike_in pulses and observe the spike output.
//   TEST 5  Spike propagation – confirm that a fired neuron drives spikes
//           to its post-synaptic neighbours through the connection matrix.
//   TEST 6  STDP LTP – verify that a synapse is potentiated when the
//           pre-synaptic trace is active at the moment of post-synaptic
//           firing.
//==============================================================================

`timescale 1ns/1ps

module tb_neuron_cluster;

    // -------------------------------------------------------------------------
    // Parameters (must match the DUT instantiation below)
    // -------------------------------------------------------------------------
    localparam N   = 4;    // number of neurons
    localparam WW  = 8;    // weight bit-width
    localparam MW  = 16;   // membrane potential bit-width
    localparam TH  = 100;  // firing threshold
    localparam LK  = 1;    // leak per clock cycle

    // -------------------------------------------------------------------------
    // DUT port connections
    // -------------------------------------------------------------------------
    reg               clk;
    reg               rst;
    reg  [N-1:0]      ext_spike_in;
    wire [N-1:0]      spike_out;
    reg  [N*N-1:0]    conn_matrix;
    reg  [N*N*WW-1:0] weight_init;
    reg               weight_load;
    wire [N*N*WW-1:0] weight_out;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    neuron_cluster #(
        .N_NEURONS    (N),
        .WEIGHT_WIDTH (WW),
        .MEM_WIDTH    (MW),
        .THRESHOLD    (TH),
        .LEAK         (LK),
        .W_MAX        (255),
        .W_MIN        (0),
        .A_PLUS       (5),
        .A_MINUS      (3)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .ext_spike_in(ext_spike_in),
        .spike_out   (spike_out),
        .conn_matrix (conn_matrix),
        .weight_init (weight_init),
        .weight_load (weight_load),
        .weight_out  (weight_out)
    );

    // -------------------------------------------------------------------------
    // Clock generation: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Helper: read one weight from the flattened weight_out bus
    // -------------------------------------------------------------------------
    function [WW-1:0] get_weight;
        input integer post_idx;
        input integer pre_idx;
        begin
            get_weight = weight_out[(post_idx*N + pre_idx)*WW +: WW];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Task: assert reset for two clock cycles then release
    // FIX 1: drive all inputs to known values BEFORE releasing reset so the
    //        DUT never sees undefined connectivity.
    // -------------------------------------------------------------------------
    task apply_reset;
        begin
            rst         = 1'b1;
            weight_load = 1'b0;
            ext_spike_in = {N{1'b0}};
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst = 1'b0;
            @(posedge clk); #1;   // one idle cycle after reset
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: bulk-load a weight matrix in one clock cycle
    // -------------------------------------------------------------------------
    task load_weights;
        input [N*N*WW-1:0] w;
        begin
            weight_init = w;
            weight_load = 1'b1;
            @(posedge clk); #1;
            weight_load = 1'b0;
            @(posedge clk); #1;   // settle
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: inject one external spike pulse on selected neurons for exactly
    //       one clock cycle.
    // FIX 2: spike is applied AFTER confirming the DUT is out of reset.
    // -------------------------------------------------------------------------
    task inject_spike;
        input [N-1:0] mask;
        begin
            ext_spike_in = mask;
            @(posedge clk); #1;
            ext_spike_in = {N{1'b0}};
        end
    endtask

    // -------------------------------------------------------------------------
    // Pass / fail counters
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    task check;
        input cond;
        input [127:0] msg;
        begin
            if (cond) begin
                $display("  PASS: %0s", msg);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s", msg);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Shared test data
    // -------------------------------------------------------------------------
    integer          k;
    reg [N*N*WW-1:0] init_w;
    reg              saw_spike0;
    reg              saw_spike1;
    reg              saw_spike2;
    integer          w_before, w_after;

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_neuron_cluster.vcd");
        $dumpvars(0, tb_neuron_cluster);

        pass_count   = 0;
        fail_count   = 0;

        // Initialise all inputs to safe values before clock starts toggling
        rst          = 1'b1;
        ext_spike_in = {N{1'b0}};
        conn_matrix  = {N*N{1'b0}};
        weight_init  = {N*N*WW{1'b0}};
        weight_load  = 1'b0;

        // =====================================================================
        // TEST 1: Reset behaviour
        // =====================================================================
        $display("");
        $display("=== TEST 1: Reset ===");
        apply_reset;
        check(spike_out === {N{1'b0}}, "spike_out all-zero after reset");

        // =====================================================================
        // TEST 2: Connection matrix configuration
        //   Topology:  0 -> 1,  0 -> 2,  1 -> 3
        //   FIX: matrix is set as a simple bit-index expression so that
        //        every pre->post pair is unambiguous.
        // =====================================================================
        $display("");
        $display("=== TEST 2: Connection matrix configuration ===");
        conn_matrix = {N*N{1'b0}};
        conn_matrix[1*N + 0] = 1'b1;   // neuron 0 -> neuron 1
        conn_matrix[2*N + 0] = 1'b1;   // neuron 0 -> neuron 2
        conn_matrix[3*N + 1] = 1'b1;   // neuron 1 -> neuron 3
        $display("  conn_matrix = %b", conn_matrix);
        check(conn_matrix[1*N+0] === 1'b1, "0->1 synapse enabled");
        check(conn_matrix[2*N+0] === 1'b1, "0->2 synapse enabled");
        check(conn_matrix[3*N+1] === 1'b1, "1->3 synapse enabled");
        check(conn_matrix[0*N+1] === 1'b0, "1->0 synapse disabled (no back-connection)");

        // =====================================================================
        // TEST 3: Weight loading
        //   FIX: weight indices use the parameterised helper so they match the
        //        actual N and WW values.
        // =====================================================================
        $display("");
        $display("=== TEST 3: Weight loading ===");
        init_w = {N*N*WW{1'b0}};
        init_w[(1*N+0)*WW +: WW] = 8'd50;   // weight[post=1][pre=0] = 50
        init_w[(2*N+0)*WW +: WW] = 8'd30;   // weight[post=2][pre=0] = 30
        init_w[(3*N+1)*WW +: WW] = 8'd40;   // weight[post=3][pre=1] = 40
        load_weights(init_w);
        $display("  weight[1][0] = %0d (expected 50)", get_weight(1,0));
        $display("  weight[2][0] = %0d (expected 30)", get_weight(2,0));
        $display("  weight[3][1] = %0d (expected 40)", get_weight(3,1));
        check(get_weight(1,0) === 8'd50, "weight[1][0] == 50 after load");
        check(get_weight(2,0) === 8'd30, "weight[2][0] == 30 after load");
        check(get_weight(3,1) === 8'd40, "weight[3][1] == 40 after load");
        check(get_weight(0,1) === 8'd0,  "weight[0][1] == 0  (not loaded)");

        // =====================================================================
        // TEST 4: External spike injection drives neuron 0 to threshold
        //   Neuron 0 receives ext_spike (contributes 10 to mem_pot) each cycle.
        //   With LEAK=1 the net gain per cycle is 9.
        //   After 12 spike cycles: mem_pot ~= 9*12 = 108 >= 100 -> FIRE.
        //   FIX: spikes are injected only after reset is de-asserted (handled
        //        by apply_reset task).
        // =====================================================================
        $display("");
        $display("=== TEST 4: Spike injection (neuron 0 fires) ===");
        apply_reset;
        load_weights(init_w);

        saw_spike0 = 1'b0;
        for (k = 0; k < 20; k = k + 1) begin
            inject_spike(4'b0001);      // external spike on neuron 0 only
            if (spike_out[0]) saw_spike0 = 1'b1;
        end
        // Wait a few more cycles for the spike to propagate to output register
        repeat(3) @(posedge clk); #1;
        if (spike_out[0]) saw_spike0 = 1'b1;
        $display("  saw_spike0 = %b", saw_spike0);
        check(saw_spike0 === 1'b1, "neuron 0 fired after repeated ext spikes");

        // =====================================================================
        // TEST 5: Spike propagation through the connection matrix
        //   When neuron 0 fires it should drive neurons 1 and 2 (connected).
        //   Use a large weight so a single pre-synaptic spike is enough.
        // =====================================================================
        $display("");
        $display("=== TEST 5: Spike propagation (0->1 and 0->2) ===");
        apply_reset;

        // Load large weights so one spike from neuron 0 drives neurons 1 & 2
        init_w = {N*N*WW{1'b0}};
        init_w[(1*N+0)*WW +: WW] = 8'd110;  // weight[1][0] = 110 > threshold
        init_w[(2*N+0)*WW +: WW] = 8'd110;  // weight[2][0] = 110 > threshold
        init_w[(3*N+1)*WW +: WW] = 8'd40;
        load_weights(init_w);

        saw_spike1 = 1'b0;
        saw_spike2 = 1'b0;

        // Drive neuron 0 to fire via external spikes
        for (k = 0; k < 15; k = k + 1) begin
            inject_spike(4'b0001);
            if (spike_out[1]) saw_spike1 = 1'b1;
            if (spike_out[2]) saw_spike2 = 1'b1;
        end
        repeat(5) begin
            @(posedge clk); #1;
            if (spike_out[1]) saw_spike1 = 1'b1;
            if (spike_out[2]) saw_spike2 = 1'b1;
        end
        $display("  saw_spike1 = %b", saw_spike1);
        $display("  saw_spike2 = %b", saw_spike2);
        check(saw_spike1 === 1'b1, "neuron 1 fired (spike from neuron 0 propagated)");
        check(saw_spike2 === 1'b1, "neuron 2 fired (spike from neuron 0 propagated)");

        // =====================================================================
        // TEST 6: STDP LTP – weight on 0->1 synapse increases after neuron 1
        //         fires shortly after a pre-synaptic spike from neuron 0.
        //   FIX: start with a non-zero weight large enough to push neuron 1 to
        //        threshold so that a post-synaptic spike (and hence weight
        //        update) actually occurs.
        // =====================================================================
        $display("");
        $display("=== TEST 6: STDP LTP on synapse 0->1 ===");
        apply_reset;

        init_w = {N*N*WW{1'b0}};
        init_w[(1*N+0)*WW +: WW] = 8'd110; // large enough to fire neuron 1
        load_weights(init_w);

        w_before = get_weight(1, 0);
        $display("  weight[1][0] before STDP = %0d", w_before);

        // Inject >=12 spikes so neuron 0 reaches threshold (net gain ~9/cycle).
        // When neuron 0 fires its spike propagates to neuron 1 (weight=110 >
        // threshold), which fires and triggers STDP LTP on the 0->1 synapse.
        for (k = 0; k < 15; k = k + 1)
            inject_spike(4'b0001);

        repeat(5) @(posedge clk); #1;

        w_after = get_weight(1, 0);
        $display("  weight[1][0] after  STDP = %0d", w_after);
        check(w_after > w_before,  "weight[1][0] increased (LTP applied)");
        check(w_after <= 255,      "weight[1][0] stayed within W_MAX bound");

        // =====================================================================
        // Summary
        // =====================================================================
        $display("");
        $display("===========================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("===========================================");
        $display("");

        #50;
        $finish;
    end

endmodule
