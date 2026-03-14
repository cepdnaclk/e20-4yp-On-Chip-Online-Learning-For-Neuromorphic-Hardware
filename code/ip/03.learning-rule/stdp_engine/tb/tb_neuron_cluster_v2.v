// =============================================================================
// Testbench: tb_neuron_cluster (v2 — 8-neuron, extended scenarios)
// Changes from v1:
//   - Expanded to 8 neurons (NUM_NEURONS_PER_CLUSTER = 8)
//   - Tests multi-input STDP: neuron 0 receives from neurons 1, 2, and 3
//   - Tests LTD: neuron with zero pre-trace gets weight reduced
//   - Tests weight saturation: LTP pushing weight to 0xFF boundary
//   - Tests fully saturated trace (saturation flag set): weight must not change
//   - Tests three-way simultaneous spike serialization
//   - Tests chain: neuron A fires → distributes weights → neuron B fires next
//   - All hex files replaced with inline initialization for portability
//
// HIERARCHICAL PATH NOTE:
//   All force/release and direct memory access paths use the naming convention
//   from neuron_cluster.v. Update the paths marked "UPDATE PATH" if your
//   instance names differ.
//     gen_neurons[i].neuron_inst   → generate block wrapping neuron instances
//     connection_matrix_inst       → cluster_connection_matrix instance
//     trace_memory_inst            → trace_memory instance
//     weight_memory_inst           → banked_weight_memory instance
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// Neuron stub — module name must match instantiation inside neuron_cluster.v
// =============================================================================
module simple_LIF_Neuron_Model #(
    parameter WEIGHT_BIT_WIDTH = 8
)(
    input  wire                         clock,
    input  wire                         reset,
    input  wire                         enable,
    input  wire                         input_spike_wire,
    input  wire [WEIGHT_BIT_WIDTH-1:0]  weight_input,
    output reg                          spike_output_wire
);
    always @(posedge clock) begin
        if (reset || !enable)
            spike_output_wire <= 1'b0;
        // Testbench injects spikes via force/release
    end
endmodule

// =============================================================================
// Main testbench
// =============================================================================
module tb_neuron_cluster;

    // =========================================================================
    // Timing parameters
    // =========================================================================
    parameter CLK_PERIOD_NS         = 10;
    parameter MAX_SIMULATION_CYCLES = 200000;
    parameter MAX_STDP_WAIT_CYCLES  = 1000;   // increased for 8-neuron STDP

    // =========================================================================
    // Design parameters — 8-neuron cluster
    // =========================================================================
    parameter NUM_NEURONS_PER_CLUSTER    = 8;
    parameter NEURON_ADDRESS_WIDTH       = 3;   // clog2(8)
    parameter NUM_WEIGHT_BANKS           = 8;
    parameter WEIGHT_BANK_ADDRESS_WIDTH  = 3;
    parameter WEIGHT_BIT_WIDTH           = 8;
    parameter TRACE_VALUE_BIT_WIDTH      = 8;
    parameter DECAY_TIMER_BIT_WIDTH      = 12;
    parameter TRACE_SATURATION_THRESHOLD = 256;
    parameter DECAY_SHIFT_LOG2           = 3;
    parameter TRACE_INCREMENT_VALUE      = 32;
    parameter NUM_TRACE_UPDATE_MODULES   = 8;
    parameter SPIKE_QUEUE_DEPTH          = 8;
    parameter LTP_SHIFT_AMOUNT           = 2;
    parameter LTD_SHIFT_AMOUNT           = 2;
    parameter INCREASE_MODE              = 0;   // SET_MAX → trace = 0xFF on spike

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg  clock;
    reg  reset;
    reg  global_cluster_enable;
    reg  decay_enable_pulse;
    reg  [NUM_NEURONS_PER_CLUSTER-1:0] external_spike_input_bus;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] cluster_spike_output_bus;
    wire                               cluster_busy_flag;

    // =========================================================================
    // DUT
    // =========================================================================
    neuron_cluster #(
        .NUM_NEURONS_PER_CLUSTER    (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH       (NEURON_ADDRESS_WIDTH),
        .NUM_WEIGHT_BANKS           (NUM_WEIGHT_BANKS),
        .WEIGHT_BANK_ADDRESS_WIDTH  (WEIGHT_BANK_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH           (WEIGHT_BIT_WIDTH),
        .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
        .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
        .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
        .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
        .NUM_TRACE_UPDATE_MODULES   (NUM_TRACE_UPDATE_MODULES),
        .SPIKE_QUEUE_DEPTH          (SPIKE_QUEUE_DEPTH),
        .LTP_SHIFT_AMOUNT           (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT           (LTD_SHIFT_AMOUNT),
        .INCREASE_MODE              (INCREASE_MODE)
    ) uut (
        .clock                    (clock),
        .reset                    (reset),
        .global_cluster_enable    (global_cluster_enable),
        .decay_enable_pulse       (decay_enable_pulse),
        .external_spike_input_bus (external_spike_input_bus),
        .cluster_spike_output_bus (cluster_spike_output_bus),
        .cluster_busy_flag        (cluster_busy_flag)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clock = 0;
    always #(CLK_PERIOD_NS / 2) clock = ~clock;

    // =========================================================================
    // Test counters
    // =========================================================================
    integer pass_count;
    integer fail_count;
    integer test_num;
    integer wait_cycles;
    integer i;

    initial begin
        pass_count  = 0;
        fail_count  = 0;
        test_num    = 0;
        wait_cycles = 0;
    end

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin
        #(CLK_PERIOD_NS * MAX_SIMULATION_CYCLES);
        $display("[WATCHDOG] Exceeded %0d cycles. Results so far: %0d/%0d passed.",
                 MAX_SIMULATION_CYCLES, pass_count, test_num);
        $finish;
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_neuron_cluster.vcd");
        $dumpvars(0, tb_neuron_cluster);
    end

    // =========================================================================
    // Task: check_result
    // =========================================================================
    task check_result;
        input       condition;
        input [8*80-1:0] label;
        begin
            test_num = test_num + 1;
            if (condition) begin
                $display("[PASS] T%02d: %0s", test_num, label);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] T%02d: %0s", test_num, label);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Task: wait_for_idle
    // Polls cluster_busy_flag. Sets timed_out=1 if budget exceeded.
    // =========================================================================
    reg timed_out_flag;

    task wait_for_idle;
        output reg timed_out;
        begin
            timed_out   = 1'b0;
            wait_cycles = 0;
            while (cluster_busy_flag && wait_cycles < MAX_STDP_WAIT_CYCLES) begin
                @(posedge clock);
                wait_cycles = wait_cycles + 1;
            end
            #1;
            if (cluster_busy_flag) begin
                timed_out = 1'b1;
                $display("       [TIMEOUT] busy after %0d cycles — check FSM/queue",
                         MAX_STDP_WAIT_CYCLES);
            end
        end
    endtask

    // =========================================================================
    // Task: inject_spike
    // Forces spike_output_wire on a specific neuron for exactly one clock cycle.
    // case statement required — iverilog does not support indexed force.
    // UPDATE PATH: update gen_neurons[*].neuron_inst to match neuron_cluster.v
    // =========================================================================
    task inject_spike;
        input [NEURON_ADDRESS_WIDTH-1:0] idx;
        begin
            case (idx)
                3'd0: force uut.gen_neurons[0].neuron_inst.spike_output_wire = 1'b1;
                3'd1: force uut.gen_neurons[1].neuron_inst.spike_output_wire = 1'b1;
                3'd2: force uut.gen_neurons[2].neuron_inst.spike_output_wire = 1'b1;
                3'd3: force uut.gen_neurons[3].neuron_inst.spike_output_wire = 1'b1;
                3'd4: force uut.gen_neurons[4].neuron_inst.spike_output_wire = 1'b1;
                3'd5: force uut.gen_neurons[5].neuron_inst.spike_output_wire = 1'b1;
                3'd6: force uut.gen_neurons[6].neuron_inst.spike_output_wire = 1'b1;
                3'd7: force uut.gen_neurons[7].neuron_inst.spike_output_wire = 1'b1;
                default: $display("[TB] inject_spike: invalid index %0d", idx);
            endcase
            @(posedge clock); #1;
            case (idx)
                3'd0: release uut.gen_neurons[0].neuron_inst.spike_output_wire;
                3'd1: release uut.gen_neurons[1].neuron_inst.spike_output_wire;
                3'd2: release uut.gen_neurons[2].neuron_inst.spike_output_wire;
                3'd3: release uut.gen_neurons[3].neuron_inst.spike_output_wire;
                3'd4: release uut.gen_neurons[4].neuron_inst.spike_output_wire;
                3'd5: release uut.gen_neurons[5].neuron_inst.spike_output_wire;
                3'd6: release uut.gen_neurons[6].neuron_inst.spike_output_wire;
                3'd7: release uut.gen_neurons[7].neuron_inst.spike_output_wire;
                default: ;
            endcase
        end
    endtask

    // =========================================================================
    // Task: apply_decay_pulses
    // Issues N decay enable pulses, each on its own clock cycle.
    // =========================================================================
    task apply_decay_pulses;
        input integer n;
        integer d;
        begin
            for (d = 0; d < n; d = d + 1) begin
                @(negedge clock);
                decay_enable_pulse = 1'b1;
                @(posedge clock); #1;
                decay_enable_pulse = 1'b0;
            end
        end
    endtask

    // =========================================================================
    // Task: set_connection
    // Directly writes one entry in the connection matrix.
    //   MSB (bit 1): column neuron is an INPUT to row neuron
    //   LSB (bit 0): row neuron OUTPUTS to column neuron
    // UPDATE PATH: update connection_matrix_inst.connection_table
    // =========================================================================
    task set_connection;
        input [NEURON_ADDRESS_WIDTH-1:0] row_neuron;
        input [NEURON_ADDRESS_WIDTH-1:0] col_neuron;
        input [1:0]                      connection_bits;
        begin
            uut.connection_matrix_inst.connection_table[row_neuron][col_neuron]
                = connection_bits;
        end
    endtask

    // =========================================================================
    // Task: set_trace
    // Writes a trace entry directly into trace memory.
    // Layout: {saturated(1), timestamp(12), value(8)} = 21 bits
    // UPDATE PATH: update trace_memory_inst.trace_entries
    // =========================================================================
    task set_trace;
        input [NEURON_ADDRESS_WIDTH-1:0]   neuron_idx;
        input [TRACE_VALUE_BIT_WIDTH-1:0]  trace_val;
        input [DECAY_TIMER_BIT_WIDTH-1:0]  timestamp;
        input                              saturated;
        begin
            uut.trace_memory_inst.trace_entries[neuron_idx]
                = {saturated, timestamp, trace_val};
        end
    endtask

    // =========================================================================
    // Task: set_weight
    // Writes a weight into the banked memory using the physical bank formula.
    // Bank B = (post + pre) % N,  Address = post
    // UPDATE PATH: update weight_memory_inst.bank_memory
    // =========================================================================
    task set_weight;
        input [NEURON_ADDRESS_WIDTH-1:0] post_neuron;
        input [NEURON_ADDRESS_WIDTH-1:0] pre_neuron;
        input [WEIGHT_BIT_WIDTH-1:0]     weight_val;
        reg   [NEURON_ADDRESS_WIDTH-1:0] bank;
        begin
            bank = (post_neuron + pre_neuron) & (NUM_WEIGHT_BANKS - 1);
            uut.weight_memory_inst.bank_memory[bank][post_neuron] = weight_val;
        end
    endtask

    // =========================================================================
    // Task: read_weight
    // Reads a weight using the physical bank formula. Result in read_weight_out.
    // =========================================================================
    reg [WEIGHT_BIT_WIDTH-1:0] read_weight_out;
    task read_weight;
        input [NEURON_ADDRESS_WIDTH-1:0] post_neuron;
        input [NEURON_ADDRESS_WIDTH-1:0] pre_neuron;
        reg   [NEURON_ADDRESS_WIDTH-1:0] bank;
        begin
            bank = (post_neuron + pre_neuron) & (NUM_WEIGHT_BANKS - 1);
            read_weight_out
                = uut.weight_memory_inst.bank_memory[bank][post_neuron];
        end
    endtask

    // =========================================================================
    // Task: read_trace
    // Reads a trace entry. Result fields in read_trace_* outputs.
    // =========================================================================
    reg [TRACE_VALUE_BIT_WIDTH-1:0] read_trace_value;
    reg [DECAY_TIMER_BIT_WIDTH-1:0] read_trace_timestamp;
    reg                             read_trace_saturated;
    task read_trace;
        input [NEURON_ADDRESS_WIDTH-1:0] neuron_idx;
        reg [20:0] entry;
        begin
            entry               = uut.trace_memory_inst.trace_entries[neuron_idx];
            read_trace_value     = entry[7:0];
            read_trace_timestamp = entry[19:8];
            read_trace_saturated = entry[20];
        end
    endtask

    // =========================================================================
    // Functions: STDP expected-value computation
    // Mirrors the default weight_update_logic (spec §4.7) and the
    // trace_update_module barrel-shift decay (spec §4.4) exactly.
    // =========================================================================

    function [WEIGHT_BIT_WIDTH-1:0] ltp_result;
        input [WEIGHT_BIT_WIDTH-1:0]      w;
        input [TRACE_VALUE_BIT_WIDTH-1:0] pre;
        reg   [WEIGHT_BIT_WIDTH:0] s;
        begin
            s = {1'b0, w} + (pre >> LTP_SHIFT_AMOUNT);
            ltp_result = s[WEIGHT_BIT_WIDTH] ? {WEIGHT_BIT_WIDTH{1'b1}} : s[WEIGHT_BIT_WIDTH-1:0];
        end
    endfunction

    function [WEIGHT_BIT_WIDTH-1:0] ltd_result;
        input [WEIGHT_BIT_WIDTH-1:0]      w;
        input [TRACE_VALUE_BIT_WIDTH-1:0] post;
        reg   [WEIGHT_BIT_WIDTH-1:0] d;
        begin
            d = post >> LTD_SHIFT_AMOUNT;
            ltd_result = (w < d) ? {WEIGHT_BIT_WIDTH{1'b0}} : w - d;
        end
    endfunction

    function [TRACE_VALUE_BIT_WIDTH-1:0] decayed_trace;
        input [TRACE_VALUE_BIT_WIDTH-1:0] val;
        input [DECAY_TIMER_BIT_WIDTH-1:0] delta_t;
        reg [3:0] sh;  // max shift for 8-bit trace is 8
        reg [TRACE_VALUE_BIT_WIDTH-1:0] s;
        reg corr;
        begin
            if (delta_t >= TRACE_SATURATION_THRESHOLD) begin
                decayed_trace = 0;
            end else begin
                sh = delta_t >> DECAY_SHIFT_LOG2;
                if (sh >= TRACE_VALUE_BIT_WIDTH) begin
                    decayed_trace = 0;
                end else begin
                    s = val >> sh;
                    if (sh > 0) begin
                        corr = (val >> (sh - 1)) & 1'b1;
                        if (corr) s = (&s) ? s : s + 1;
                    end
                    decayed_trace = s;
                end
            end
        end
    endfunction

    // =========================================================================
    // Test state variables
    // =========================================================================
    reg [WEIGHT_BIT_WIDTH-1:0]      actual_w;
    reg [WEIGHT_BIT_WIDTH-1:0]      expected_w;
    reg [TRACE_VALUE_BIT_WIDTH-1:0] eff_trace;

    // =========================================================================
    //
    //  CONNECTION TOPOLOGY USED IN THIS TESTBENCH
    //  (Configured during SETUP PHASE below)
    //
    //  Inputs to neuron 0  : neurons 1, 2, 3  (connection_table[0][1..3] MSB=1)
    //  Outputs from neuron 0: neuron 4, 5     (connection_table[0][4..5] LSB=1)
    //  Inputs to neuron 5  : neuron 6         (connection_table[5][6] MSB=1)
    //  Outputs from neuron 5: neuron 7        (connection_table[5][7] LSB=1)
    //  (All other entries zero)
    //
    //  BANKED WEIGHT FORMULA (N=8):
    //    Bank B = (post + pre) mod 8,  Address = post
    //
    //  Weights pre-loaded:
    //    W[0][1] = 80  → Bank (0+1)%8=1, Addr 0
    //    W[0][2] = 60  → Bank (0+2)%8=2, Addr 0
    //    W[0][3] = 40  → Bank (0+3)%8=3, Addr 0
    //    W[5][6] = 100 → Bank (5+6)%8=3, Addr 5
    //
    //  Traces pre-loaded:
    //    Neuron 1: value=120, timestamp=0, saturated=0
    //    Neuron 2: value= 80, timestamp=0, saturated=0
    //    Neuron 3: value=  0, timestamp=0, saturated=0  (zero → LTD on W[0][3])
    //    Neuron 6: value= 64, timestamp=0, saturated=0
    //    Neuron 4: value=255, saturated=1               (fully saturated)
    //
    // =========================================================================

    localparam W_0_1_INIT  = 8'd80;
    localparam W_0_2_INIT  = 8'd60;
    localparam W_0_3_INIT  = 8'd40;
    localparam W_5_6_INIT  = 8'd100;

    localparam TR_N1_INIT  = 8'd120;
    localparam TR_N2_INIT  = 8'd80;
    localparam TR_N3_INIT  = 8'd0;    // zero pre-trace → LTD
    localparam TR_N6_INIT  = 8'd64;

    localparam POST_TRACE_MAX = 8'hFF;

    // =========================================================================
    // MAIN TEST BODY
    // =========================================================================
    initial begin
        $display("===============================================================");
        $display("  tb_neuron_cluster v2 — 8-neuron Extended Testbench");
        $display("  CLK_PERIOD_NS         : %0d ns", CLK_PERIOD_NS);
        $display("  MAX_SIMULATION_CYCLES : %0d", MAX_SIMULATION_CYCLES);
        $display("  MAX_STDP_WAIT_CYCLES  : %0d", MAX_STDP_WAIT_CYCLES);
        $display("  NUM_NEURONS_PER_CLUSTER: %0d", NUM_NEURONS_PER_CLUSTER);
        $display("===============================================================");

        // ---- Reset ----
        reset                    = 1;
        global_cluster_enable    = 0;
        decay_enable_pulse       = 0;
        external_spike_input_bus = 0;
        repeat(4) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // ============================================================
        // GROUP A: Basic sanity
        // ============================================================
        $display("\n--- GROUP A: Basic sanity ---");

        // T01: idle after reset
        check_result(!cluster_busy_flag, "Cluster idle after reset");

        // T02: spike bus zero after reset
        check_result(cluster_spike_output_bus === 8'b0,
            "cluster_spike_output_bus = 0 after reset");

        // ============================================================
        // SETUP PHASE — inline initialization, no hex files
        // ============================================================
        $display("\n--- SETUP: Connections, weights, traces ---");

        // Connection matrix
        // Inputs to neuron 0
        set_connection(0, 1, 2'b10);  // neuron 1 is input to neuron 0
        set_connection(0, 2, 2'b10);  // neuron 2 is input to neuron 0
        set_connection(0, 3, 2'b10);  // neuron 3 is input to neuron 0
        // Outputs from neuron 0
        set_connection(0, 4, 2'b01);  // neuron 0 outputs to neuron 4
        set_connection(0, 5, 2'b01);  // neuron 0 outputs to neuron 5
        // Input to neuron 5
        set_connection(5, 6, 2'b10);  // neuron 6 is input to neuron 5
        // Output from neuron 5
        set_connection(5, 7, 2'b01);  // neuron 5 outputs to neuron 7
        @(posedge clock); #1;

        // Weights
        set_weight(0, 1, W_0_1_INIT);
        set_weight(0, 2, W_0_2_INIT);
        set_weight(0, 3, W_0_3_INIT);
        set_weight(5, 6, W_5_6_INIT);
        @(posedge clock); #1;

        // Traces
        set_trace(1, TR_N1_INIT,  12'd0, 1'b0);  // pre for W[0][1]
        set_trace(2, TR_N2_INIT,  12'd0, 1'b0);  // pre for W[0][2]
        set_trace(3, TR_N3_INIT,  12'd0, 1'b0);  // pre for W[0][3] (zero → LTD)
        set_trace(6, TR_N6_INIT,  12'd0, 1'b0);  // pre for W[5][6]
        set_trace(4, 8'hFF,       12'd0, 1'b1);  // neuron 4 saturated (no effect)
        @(posedge clock); #1;

        // T03: Verify setup — weight W[0][1]
        read_weight(0, 1);
        check_result(read_weight_out === W_0_1_INIT,
            "Setup: W[0][1]=80 confirmed in Bank 1 Addr 0");

        // T04: Verify setup — weight W[0][3]
        read_weight(0, 3);
        check_result(read_weight_out === W_0_3_INIT,
            "Setup: W[0][3]=40 confirmed in Bank 3 Addr 0");

        // T05: Verify setup — neuron 3 trace zero
        read_trace(3);
        check_result(read_trace_value === 8'd0 && read_trace_saturated === 1'b0,
            "Setup: neuron 3 trace=0, saturated=0 confirmed");

        // T06: Verify setup — neuron 4 trace saturated
        read_trace(4);
        check_result(read_trace_saturated === 1'b1,
            "Setup: neuron 4 trace saturated flag = 1 confirmed");

        // ============================================================
        // GROUP B: Single-input STDP — neuron 0 fires, 3 pre-synaptics
        // ============================================================
        $display("\n--- GROUP B: Multi-input STDP — neuron 0 fires ---");
        $display("    Inputs: N1(tr=120,LTP), N2(tr=80,LTP), N3(tr=0,LTD)");
        $display("    Expected: W[0][1]=80+30=110, W[0][2]=60+20=80, W[0][3]=40-63=0");

        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;

        inject_spike(3'd0);
        repeat(5) @(posedge clock); #1;

        // T07: FSM went busy
        check_result(cluster_busy_flag,
            "B: cluster_busy after neuron 0 fires");

        wait_for_idle(timed_out_flag);

        // T08: completed in time
        check_result(!timed_out_flag,
            "B: STDP cycle completes within budget");
        $display("       Completed in %0d cycles", wait_cycles);

        #2;

        // T09: LTP on W[0][1] — pre_trace=120, delta=120>>2=30, 80+30=110
        read_weight(0, 1);
        expected_w = ltp_result(W_0_1_INIT, TR_N1_INIT);
        check_result(read_weight_out === expected_w,
            "B: LTP W[0][1]: 80 + 30 = 110");
        if (read_weight_out !== expected_w)
            $display("       Expected %0d, got %0d", expected_w, read_weight_out);

        // T10: LTP on W[0][2] — pre_trace=80, delta=80>>2=20, 60+20=80
        read_weight(0, 2);
        expected_w = ltp_result(W_0_2_INIT, TR_N2_INIT);
        check_result(read_weight_out === expected_w,
            "B: LTP W[0][2]: 60 + 20 = 80");
        if (read_weight_out !== expected_w)
            $display("       Expected %0d, got %0d", expected_w, read_weight_out);

        // T11: LTD on W[0][3] — pre_trace=0 → use post_trace=0xFF=255
        //      delta = 255>>2 = 63, 40-63 → clamp to 0
        read_weight(0, 3);
        expected_w = ltd_result(W_0_3_INIT, POST_TRACE_MAX);
        check_result(read_weight_out === expected_w,
            "B: LTD W[0][3]: 40-63 saturates to 0");
        if (read_weight_out !== expected_w)
            $display("       Expected %0d, got %0d", expected_w, read_weight_out);

        // T12: Post-synaptic trace of neuron 0 written as SET_MAX
        read_trace(0);
        check_result(read_trace_value === POST_TRACE_MAX && read_trace_saturated === 1'b0,
            "B: Neuron 0 post-trace = 0xFF, saturated=0");

        // T13: Idle after first STDP
        check_result(!cluster_busy_flag, "B: Cluster idle after STDP");

        // ============================================================
        // GROUP C: Decay effect on LTP magnitude
        // Apply 8 decay pulses, then fire neuron 0 again.
        // Pre-traces decay: N1: 120→decayed, N2: 80→decayed
        // N3 was zero → still LTD but post-trace also decayed now
        // ============================================================
        $display("\n--- GROUP C: STDP after 8 decay ticks ---");

        apply_decay_pulses(8);
        #1;

        // T14: No STDP triggered by decay pulses
        check_result(!cluster_busy_flag,
            "C: Cluster stays idle during 8 decay pulses");

        // T15: Neuron 0 raw trace unchanged by decay (lazy)
        read_trace(0);
        check_result(read_trace_value === POST_TRACE_MAX,
            "C: Neuron 0 raw trace still 0xFF (lazy decay, no in-place update)");

        // Compute decayed traces at 8 ticks
        // N1: shift = 8>>3 = 1, decayed(120,8) = 120>>1 = 60, corr=(120>>0)&1=0 → 60
        // N2: shift = 1,  decayed(80,8)  = 80>>1  = 40, corr=(80>>0)&1=0 → 40
        // Post trace of neuron 0 as decayed for LTD check:
        //   decayed(0xFF,8) = 255>>1=127, corr=(255>>0)&1=1 → 128

        inject_spike(3'd0);
        repeat(5) @(posedge clock); #1;

        check_result(cluster_busy_flag, "C: Busy after second neuron 0 fire");

        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag, "C: STDP cycle 2 completes within budget");
        $display("       Completed in %0d cycles", wait_cycles);

        #2;

        // Weight before this cycle was the result of GROUP B
        // Save GROUP B results for use as starting weights
        // W[0][1] after B = ltp_result(80, 120) = 110
        // W[0][2] after B = ltp_result(60, 80)  = 80
        // W[0][3] after B = ltd_result(40, 255) = 0

        // T16: LTP on W[0][1] with decayed pre-trace
        read_weight(0, 1);
        eff_trace  = decayed_trace(TR_N1_INIT, 12'd8);
        expected_w = ltp_result(ltp_result(W_0_1_INIT, TR_N1_INIT), eff_trace);
        check_result(read_weight_out === expected_w,
            "C: LTP W[0][1] with decayed pre-trace (120→60, delta=15)");
        if (read_weight_out !== expected_w)
            $display("       eff_trace=%0d expected=%0d got=%0d",
                     eff_trace, expected_w, read_weight_out);

        // T17: LTP on W[0][2] with decayed pre-trace
        read_weight(0, 2);
        eff_trace  = decayed_trace(TR_N2_INIT, 12'd8);
        expected_w = ltp_result(ltp_result(W_0_2_INIT, TR_N2_INIT), eff_trace);
        check_result(read_weight_out === expected_w,
            "C: LTP W[0][2] with decayed pre-trace (80→40, delta=10)");
        if (read_weight_out !== expected_w)
            $display("       eff_trace=%0d expected=%0d got=%0d",
                     eff_trace, expected_w, read_weight_out);

        // T18: W[0][3] already zero after GROUP B — LTD on zero stays zero
        read_weight(0, 3);
        check_result(read_weight_out === 8'd0,
            "C: LTD W[0][3] stays 0 (already floored)");

        // ============================================================
        // GROUP D: Saturated pre-trace — weight must not change
        // Neuron 4 has saturated_flag=1. If neuron 5 fires (neuron 4
        // is NOT an input to 5, so this tests that saturated traces of
        // unconnected neurons do not bleed into computation).
        // Actually test: configure neuron 5 with neuron 4 as input,
        // then fire neuron 5 and verify W[5][4] is LTD (pre=0 from
        // saturated → effective trace = 0).
        // ============================================================
        $display("\n--- GROUP D: Saturated pre-trace gives zero effective pre-trace ---");

        // Add connection: neuron 4 is input to neuron 5
        set_connection(5, 4, 2'b10);
        // Set weight W[5][4] to something non-zero so we can detect change
        set_weight(5, 4, 8'd50);
        // Neuron 4 trace is still saturated (set in SETUP)
        @(posedge clock); #1;

        inject_spike(3'd5);
        repeat(5) @(posedge clock); #1;

        check_result(cluster_busy_flag, "D: Busy after neuron 5 fires");

        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag, "D: STDP completes for neuron 5");

        #2;

        // Saturated neuron 4 → effective pre-trace = 0 → LTD applies
        // post_trace for neuron 5 = SET_MAX = 0xFF
        // LTD: delta = 0xFF>>2 = 63, 50-63 → clamp to 0
        read_weight(5, 4);
        expected_w = ltd_result(8'd50, POST_TRACE_MAX);
        check_result(read_weight_out === expected_w,
            "D: Saturated pre-trace → effective=0 → LTD applied to W[5][4]");
        if (read_weight_out !== expected_w)
            $display("       expected=%0d got=%0d", expected_w, read_weight_out);

        // T21: W[5][6] unchanged (neuron 6 is also input to 5, but
        //      its trace has NOT decayed to zero — LTP should still apply)
        read_weight(5, 6);
        // Neuron 6 trace was set at t=0 with value=64.
        // 8 decay ticks have passed since GROUP C started.
        // But neuron 5 has not fired yet until now — decay from t=0 to now.
        // We applied 8 ticks before GROUP C. Neuron 6 trace: decayed(64, 8)
        //   shift=1, 64>>1=32, corr=(64>>0)&1=0 → 32
        eff_trace  = decayed_trace(TR_N6_INIT, 12'd8);
        expected_w = ltp_result(W_5_6_INIT, eff_trace);
        check_result(read_weight_out === expected_w,
            "D: LTP W[5][6] with decayed neuron 6 trace");
        if (read_weight_out !== expected_w)
            $display("       eff_trace=%0d expected=%0d got=%0d",
                     eff_trace, expected_w, read_weight_out);

        // ============================================================
        // GROUP E: Three simultaneous spikes — queue serialization
        // Neurons 1, 2, 3 fire at the same clock edge.
        // Queue must serialize them and hold busy until all 3 STDP
        // cycles complete.
        // ============================================================
        $display("\n--- GROUP E: Three simultaneous spikes (neurons 1, 2, 3) ---");

        force uut.gen_neurons[1].neuron_inst.spike_output_wire = 1'b1;
        force uut.gen_neurons[2].neuron_inst.spike_output_wire = 1'b1;
        force uut.gen_neurons[3].neuron_inst.spike_output_wire = 1'b1;
        @(posedge clock); #1;
        release uut.gen_neurons[1].neuron_inst.spike_output_wire;
        release uut.gen_neurons[2].neuron_inst.spike_output_wire;
        release uut.gen_neurons[3].neuron_inst.spike_output_wire;

        repeat(4) @(posedge clock); #1;

        // T22: Cluster busy (queue has 3 entries)
        check_result(cluster_busy_flag,
            "E: Cluster busy after 3 simultaneous spikes");

        wait_for_idle(timed_out_flag);

        // T23: All three STDP cycles completed
        check_result(!timed_out_flag,
            "E: All 3 simultaneous STDP cycles complete within budget");
        $display("       All 3 completed in %0d cycles", wait_cycles);

        // T24: Post-traces for neurons 1, 2, 3 all updated to SET_MAX
        read_trace(1);
        check_result(read_trace_value === POST_TRACE_MAX && !read_trace_saturated,
            "E: Neuron 1 post-trace = 0xFF after its STDP");
        read_trace(2);
        check_result(read_trace_value === POST_TRACE_MAX && !read_trace_saturated,
            "E: Neuron 2 post-trace = 0xFF after its STDP");
        read_trace(3);
        check_result(read_trace_value === POST_TRACE_MAX && !read_trace_saturated,
            "E: Neuron 3 post-trace = 0xFF after its STDP");

        // ============================================================
        // GROUP F: LTP weight saturation boundary
        // Push W[0][1] to near 0xFF then fire again — must saturate
        // ============================================================
        $display("\n--- GROUP F: LTP weight saturation at 0xFF ---");

        // Force W[0][1] close to max: 0xF0 = 240
        set_weight(0, 1, 8'hF0);
        // Reload neuron 1 trace to high value
        set_trace(1, 8'hFF, 12'd0, 1'b0);
        @(posedge clock); #1;

        inject_spike(3'd0);
        repeat(5) @(posedge clock); #1;
        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag, "F: STDP completes for saturation test");

        #2;
        read_weight(0, 1);
        // LTP: delta = 0xFF>>2 = 63, 240+63 = 303 > 255 → saturate to 255
        expected_w = ltp_result(8'hF0, 8'hFF);
        check_result(read_weight_out === 8'hFF,
            "F: LTP saturates W[0][1] at 0xFF");
        if (read_weight_out !== 8'hFF)
            $display("       expected=255 got=%0d", read_weight_out);

        // ============================================================
        // GROUP G: No-connection spike — trivial STDP
        // Neuron 7 has no connections configured. STDP should complete
        // (only post-trace increase) and no weights change.
        // ============================================================
        $display("\n--- GROUP G: No-connection spike (neuron 7) ---");

        // Save current W[0][1] = 0xFF (saturated from GROUP F)
        read_weight(0, 1);
        actual_w = read_weight_out;

        inject_spike(3'd7);
        repeat(4) @(posedge clock); #1;
        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag,
            "G: No-connection STDP completes quickly");

        #2;
        read_weight(0, 1);
        check_result(read_weight_out === actual_w,
            "G: W[0][1] unchanged after unconnected neuron 7 fires");

        // T29: Neuron 7 post-trace updated
        read_trace(7);
        check_result(read_trace_value === POST_TRACE_MAX && !read_trace_saturated,
            "G: Neuron 7 post-trace = 0xFF");

        // ============================================================
        // GROUP H: Weight distribution bus check
        // Fire neuron 0 and verify weights are placed on distribution
        // bus for neurons 4 and 5 (LSB connections configured in SETUP).
        // We read weight_distribution_receiver held values after busy clears.
        // ============================================================
        $display("\n--- GROUP H: Weight distribution to post-synaptic neurons ---");

        // Restore a known weight for distribution check
        set_weight(0, 4, 8'd55);  // W[0→4] in the column sense: W[4][0]
        set_weight(0, 5, 8'd77);  // W[0→5] in the column sense: W[5][0]
        // Actually for column access: fired pre=0, targeting post k:
        //   Bank = (k + 0) % 8 = k, Address = k
        // So W[4][0] at Bank 4 Addr 4, W[5][0] at Bank 5 Addr 5
        uut.weight_memory_inst.bank_memory[4][4] = 8'd55;
        uut.weight_memory_inst.bank_memory[5][5] = 8'd77;
        @(posedge clock); #1;

        inject_spike(3'd0);
        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag, "H: STDP completes for distribution test");

        #2;

        // T31 & T32: weight_distribution_receiver held values for neurons 4 and 5
        // UPDATE PATH: update receiver instance names to match neuron_cluster.v
        check_result(
            uut.gen_receivers[4].receiver_inst.held_weight_value === 8'd55,
            "H: Neuron 4 weight_distribution_receiver holds W[4][0]=55");
        check_result(
            uut.gen_receivers[5].receiver_inst.held_weight_value === 8'd77,
            "H: Neuron 5 weight_distribution_receiver holds W[5][0]=77");

        // ============================================================
        // GROUP I: Mid-run reset recovery
        // ============================================================
        $display("\n--- GROUP I: Mid-run reset recovery ---");

        // Start an STDP cycle then immediately reset
        inject_spike(3'd0);
        repeat(2) @(posedge clock);
        reset = 1;
        repeat(3) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // T33: FSM returns to idle
        check_result(!cluster_busy_flag,
            "I: Cluster idle after mid-STDP reset");

        // T34: Spike output bus clean after reset
        check_result(cluster_spike_output_bus === 8'b0,
            "I: Spike output bus = 0 after reset");

        // T35: Pipeline restarts cleanly after reset
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;
        inject_spike(3'd0);
        repeat(5) @(posedge clock); #1;
        check_result(cluster_busy_flag,
            "I: Cluster busy after post-reset spike — pipeline restarted");

        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag,
            "I: Post-reset STDP cycle completes cleanly");

        // ============================================================
        // GROUP J: Rapid sequential spikes — no missed events
        // Fire neuron 0, then neuron 1 two cycles later (before first
        // STDP finishes). Queue must hold neuron 1 until neuron 0 done.
        // ============================================================
        $display("\n--- GROUP J: Rapid sequential spikes, queue holds second ---");

        inject_spike(3'd0);
        @(posedge clock); @(posedge clock); #1;  // 2 cycles later
        inject_spike(3'd1);                       // second spike while first in progress

        wait_for_idle(timed_out_flag);
        check_result(!timed_out_flag,
            "J: Both rapid sequential spikes processed without deadlock");
        $display("       Completed in %0d cycles", wait_cycles);

        // T38: Both post-traces updated
        read_trace(0);
        check_result(read_trace_value === POST_TRACE_MAX,
            "J: Neuron 0 post-trace updated after rapid sequential");
        read_trace(1);
        check_result(read_trace_value === POST_TRACE_MAX,
            "J: Neuron 1 post-trace updated after rapid sequential");

        // ============================================================
        // FINAL SUMMARY
        // ============================================================
        $display("");
        $display("===============================================================");
        $display("  FINAL RESULTS: %0d passed, %0d failed out of %0d tests",
                 pass_count, fail_count, test_num);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  FAILURES DETECTED — review [FAIL] lines above");
        $display("===============================================================");
        $finish;
    end

endmodule
