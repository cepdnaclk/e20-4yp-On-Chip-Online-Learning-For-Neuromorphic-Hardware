// =============================================================================
// Testbench: tb_neuron_cluster_v2
// 16-Neuron integration testbench.
//
// Changes from v1 (4-neuron):
//   - NUM_NEURONS_PER_CLUSTER = 16, NEURON_ADDRESS_WIDTH = 4
//   - NUM_WEIGHT_BANKS = 16, WEIGHT_BANK_ADDRESS_WIDTH = 4
//   - SPIKE_QUEUE_DEPTH = 16 (matches cluster size)
//   - Stub neuron module defined here; no real neuron files required
//   - All memory pre-loaded inline (no init_weights.hex needed)
//   - inject_spike task covers all 16 neuron indices
//   - Expanded test groups:
//       Group A: Multi-input LTP (neurons 5, 7, 9 → neuron 0)
//       Group B: Lazy-decay + second LTP (16 decay ticks)
//       Group C: LTP saturation  — W[8][14] starts at 0xFF, must not overflow
//       Group D: LTD underflow   — W[6][12] starts at 0x00, must not wrap
//       Group E: 4 simultaneous spikes — queue serialisation stress test
//       Group F: Mid-run reset and clean restart
//
// Banked weight mapping (N=16): W[post][pre] → Bank=(post+pre)%16, Addr=post
//
// Connection table bit semantics (as established in v1 spec):
//   bit[1] = other neuron is PRE-synaptic to the indexed neuron (LTP trigger)
//   bit[0] = indexed neuron is PRE-synaptic to other neuron   (LTD trigger)
//
// IMPORTANT — Hierarchical paths:
//   All force/release and direct memory access paths use the same instance
//   naming convention as v1. Update the paths marked "UPDATE PATH" if your
//   neuron_cluster.v uses different internal names.
//     generate block  : gen_neurons[i]
//     neuron instance : neuron_inst
//     weight memory   : weight_memory_inst  → bank_memory[bank][addr]
//     trace memory    : trace_memory_inst   → trace_entries[neuron_idx]
//     conn. matrix    : connection_matrix_inst → connection_table[post][other]
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// Stub neuron module
// Module name MUST match the instantiation in neuron_cluster.v:
//   simple_LIF_Neuron_Model neuron_inst (...)
// Port list matches the connection site in neuron_cluster.v exactly:
//   .clock, .reset, .enable, .input_spike_wire,
//   .synaptic_weight_wire, .spike_output_wire
// Holds spike_output_wire low at all times; testbench injects spikes via
// force/release on the hierarchical path
//   uut.gen_neurons[n].neuron_inst.spike_output_wire
// The RTL_V2 file set in the Makefile must NOT include the real neuron source
// files — this stub satisfies the module reference instead.
// =============================================================================
module simple_LIF_Neuron_Model #(
    parameter WEIGHT_BIT_WIDTH = 8
)(
    input  wire                         clock,
    input  wire                         reset,
    input  wire                         enable,
    input  wire                         input_spike_wire,
    input  wire [WEIGHT_BIT_WIDTH-1:0]  synaptic_weight_wire,
    output reg                          spike_output_wire
);
    always @(posedge clock) begin
        if (reset || !enable)
            spike_output_wire <= 1'b0;
        // spike_output_wire stays 0 unless testbench uses force to inject
    end
endmodule


// =============================================================================
// Main testbench
// =============================================================================
module tb_neuron_cluster_v2;

    // =========================================================================
    // Timing parameters
    // =========================================================================
    parameter CLK_PERIOD_NS          = 10;
    parameter MAX_SIMULATION_CYCLES  = 100000;  // raised for larger cluster
    parameter MAX_STDP_WAIT_CYCLES   = 2000;    // raised: 16 inputs per STDP cycle

    // =========================================================================
    // Design parameters — 16-neuron cluster
    // =========================================================================
    parameter NUM_NEURONS_PER_CLUSTER    = 16;
    parameter NEURON_ADDRESS_WIDTH       = 4;
    parameter NUM_WEIGHT_BANKS           = 16;
    parameter WEIGHT_BANK_ADDRESS_WIDTH  = 4;   // 16 addresses per bank
    parameter WEIGHT_BIT_WIDTH           = 8;
    parameter TRACE_VALUE_BIT_WIDTH      = 8;
    parameter DECAY_TIMER_BIT_WIDTH      = 12;
    parameter TRACE_SATURATION_THRESHOLD = 256;
    parameter DECAY_SHIFT_LOG2           = 3;
    parameter TRACE_INCREMENT_VALUE      = 32;
    parameter NUM_TRACE_UPDATE_MODULES   = 4;
    parameter SPIKE_QUEUE_DEPTH          = 16;  // one slot per neuron
    parameter LTP_SHIFT_AMOUNT           = 2;
    parameter LTD_SHIFT_AMOUNT           = 2;
    parameter INCREASE_MODE              = 0;   // SET_MAX: post trace → 0xFF

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
    // DUT instantiation
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
    // Clock generation
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
        $display("");
        $display("[WATCHDOG] Simulation exceeded %0d cycles — force stop.",
                 MAX_SIMULATION_CYCLES);
        $display("           Results so far: %0d passed, %0d failed out of %0d tests",
                 pass_count, fail_count, test_num);
        $finish;
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_neuron_cluster_v2.vcd");
        $dumpvars(0, tb_neuron_cluster_v2);
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
    // Task: wait_for_stdp_completion
    // =========================================================================
    reg timed_out_flag;

    task wait_for_stdp_completion;
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
                $display("       [TIMEOUT] busy still high after %0d cycles.",
                         MAX_STDP_WAIT_CYCLES);
                $display("       Increase MAX_STDP_WAIT_CYCLES if needed.");
            end
        end
    endtask

    // =========================================================================
    // Task: inject_spike
    // Forces spike_output_wire high on the chosen neuron for one clock cycle.
    // 16 neurons require all 16 cases enumerated — iverilog does not support
    // indexed force (force uut.gen_neurons[n].neuron_inst.spike_output_wire).
    //
    // UPDATE PATH: replace 'gen_neurons' / 'neuron_inst' with the generate
    // label and instance name used in your neuron_cluster.v.
    // =========================================================================
    task inject_spike;
        input [NEURON_ADDRESS_WIDTH-1:0] neuron_index;
        begin
            case (neuron_index)
                4'd0:  force uut.gen_neurons[0].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd1:  force uut.gen_neurons[1].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd2:  force uut.gen_neurons[2].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd3:  force uut.gen_neurons[3].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd4:  force uut.gen_neurons[4].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd5:  force uut.gen_neurons[5].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd6:  force uut.gen_neurons[6].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd7:  force uut.gen_neurons[7].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd8:  force uut.gen_neurons[8].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd9:  force uut.gen_neurons[9].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
                4'd10: force uut.gen_neurons[10].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                4'd11: force uut.gen_neurons[11].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                4'd12: force uut.gen_neurons[12].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                4'd13: force uut.gen_neurons[13].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                4'd14: force uut.gen_neurons[14].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                4'd15: force uut.gen_neurons[15].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
                default: $display("[TB] inject_spike: invalid index %0d", neuron_index);
            endcase
            @(posedge clock); #1;
            case (neuron_index)
                4'd0:  release uut.gen_neurons[0].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd1:  release uut.gen_neurons[1].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd2:  release uut.gen_neurons[2].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd3:  release uut.gen_neurons[3].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd4:  release uut.gen_neurons[4].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd5:  release uut.gen_neurons[5].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd6:  release uut.gen_neurons[6].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd7:  release uut.gen_neurons[7].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd8:  release uut.gen_neurons[8].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd9:  release uut.gen_neurons[9].neuron_inst.spike_output_wire;  // UPDATE PATH
                4'd10: release uut.gen_neurons[10].neuron_inst.spike_output_wire; // UPDATE PATH
                4'd11: release uut.gen_neurons[11].neuron_inst.spike_output_wire; // UPDATE PATH
                4'd12: release uut.gen_neurons[12].neuron_inst.spike_output_wire; // UPDATE PATH
                4'd13: release uut.gen_neurons[13].neuron_inst.spike_output_wire; // UPDATE PATH
                4'd14: release uut.gen_neurons[14].neuron_inst.spike_output_wire; // UPDATE PATH
                4'd15: release uut.gen_neurons[15].neuron_inst.spike_output_wire; // UPDATE PATH
                default: ;
            endcase
        end
    endtask

    // =========================================================================
    // Functions: expected weight after LTP / LTD
    // Mirror the weight_update_logic spec (Section 4.7).
    //
    //   LTP (pre_trace > 0):  delta = pre_trace  >> LTP_SHIFT_AMOUNT
    //                          new_w = sat_add(current_w, delta)
    //   LTD (post_trace > 0): delta = post_trace >> LTD_SHIFT_AMOUNT
    //                          new_w = sat_sub(current_w, delta)
    // =========================================================================
    function [WEIGHT_BIT_WIDTH-1:0] expected_weight_after_ltp;
        input [WEIGHT_BIT_WIDTH-1:0]      current_weight;
        input [TRACE_VALUE_BIT_WIDTH-1:0] pre_trace;
        reg [WEIGHT_BIT_WIDTH:0] sum;
        begin
            sum = {1'b0, current_weight} + (pre_trace >> LTP_SHIFT_AMOUNT);
            expected_weight_after_ltp = sum[WEIGHT_BIT_WIDTH] ?
                                        {WEIGHT_BIT_WIDTH{1'b1}} :
                                        sum[WEIGHT_BIT_WIDTH-1:0];
        end
    endfunction

    function [WEIGHT_BIT_WIDTH-1:0] expected_weight_after_ltd;
        input [WEIGHT_BIT_WIDTH-1:0]      current_weight;
        input [TRACE_VALUE_BIT_WIDTH-1:0] post_trace;
        reg [WEIGHT_BIT_WIDTH-1:0] delta;
        begin
            delta = post_trace >> LTD_SHIFT_AMOUNT;
            expected_weight_after_ltd = (current_weight < delta) ?
                                        {WEIGHT_BIT_WIDTH{1'b0}} :
                                        current_weight - delta;
        end
    endfunction

    // =========================================================================
    // Function: compute_effective_trace
    // Applies the barrel-shift-with-correction lazy decay algorithm
    // (spec Section 4.4) to produce the on-demand effective trace value.
    // =========================================================================
    function [TRACE_VALUE_BIT_WIDTH-1:0] compute_effective_trace;
        input [TRACE_VALUE_BIT_WIDTH-1:0] stored_value;
        input [DECAY_TIMER_BIT_WIDTH-1:0] delta_t;
        reg [$clog2(TRACE_VALUE_BIT_WIDTH+1)-1:0] shift_amount;
        reg [TRACE_VALUE_BIT_WIDTH-1:0] shifted;
        reg correction_bit;
        begin
            if (delta_t >= TRACE_SATURATION_THRESHOLD) begin
                compute_effective_trace = 0;
            end else begin
                shift_amount = delta_t >> DECAY_SHIFT_LOG2;
                if (shift_amount >= TRACE_VALUE_BIT_WIDTH) begin
                    compute_effective_trace = 0;
                end else begin
                    shifted = stored_value >> shift_amount;
                    if (shift_amount > 0) begin
                        correction_bit = (stored_value >> (shift_amount - 1)) & 1'b1;
                        if (correction_bit)
                            shifted = (&shifted) ? shifted : shifted + 1;
                    end
                    compute_effective_trace = shifted;
                end
            end
        end
    endfunction

    // =========================================================================
    // Memory initialisation helpers
    // =========================================================================
    integer i_bank;
    integer i_addr;

    // =========================================================================
    // Test scenario constants
    // =========================================================================
    //
    // --- Group A / B: Multi-input LTP, neuron 0 as post-synaptic ---
    //   Pre-synaptic neurons: 5, 7, 9
    //   Weight bank mapping (Bank = (post+pre) % 16, Addr = post):
    //     W[0][5]  → Bank (0+5)%16 = 5,  Addr 0
    //     W[0][7]  → Bank (0+7)%16 = 7,  Addr 0
    //     W[0][9]  → Bank (0+9)%16 = 9,  Addr 0
    //
    // --- Group C: LTP saturation ---
    //   Pre-synaptic: neuron 14 → post-synaptic: neuron 8
    //     W[8][14] → Bank (8+14)%16 = 6, Addr 8   initial = 0xFF
    //     TRACE_N14 = 0xFF; delta = 0xFF>>2 = 63; 0xFF+63 → clamp 0xFF
    //
    // --- Group D: LTD underflow ---
    //   Pre-synaptic: neuron 12 → post-synaptic: neuron 6
    //   connection_table[12][6] bit[0]=1 → neuron 12 is PRE to neuron 6
    //     W[6][12] → Bank (6+12)%16 = 2, Addr 6   initial = 0x00
    //     TRACE_N6 (post) = 0xFF; delta = 0xFF>>2 = 63; 0x00-63 → clamp 0x00
    //
    // --- Group E: 4-way simultaneous spikes (no connections) ---
    //   Neurons 1, 3, 11, 13 — spike queue must serialise all four.
    //
    // Trace memory entry layout (21 bits):
    //   [20]    = saturated_flag
    //   [19:8]  = stored_timestamp (12 bits, decay-tick count at last update)
    //   [7:0]   = trace_value (8 bits)

    localparam [WEIGHT_BIT_WIDTH-1:0] W_N5_N0_INIT   = 8'd100;
    localparam [WEIGHT_BIT_WIDTH-1:0] W_N7_N0_INIT   = 8'd80;
    localparam [WEIGHT_BIT_WIDTH-1:0] W_N9_N0_INIT   = 8'd60;
    localparam [WEIGHT_BIT_WIDTH-1:0] W_SAT_INIT     = 8'hFF;  // W[8][14] saturation
    localparam [WEIGHT_BIT_WIDTH-1:0] W_FLOOR_INIT   = 8'h00;  // W[6][12] underflow

    localparam [TRACE_VALUE_BIT_WIDTH-1:0] TRACE_N5_INIT  = 8'd128;
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] TRACE_N7_INIT  = 8'd96;
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] TRACE_N9_INIT  = 8'd64;
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] TRACE_N14_INIT = 8'hFF; // saturation test
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] TRACE_N6_INIT  = 8'hFF; // underflow test
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] POST_TRACE_MAX = 8'hFF; // SET_MAX value

    // Intermediate weight storage for second-spike LTP calculations
    reg [WEIGHT_BIT_WIDTH-1:0] w_n5_n0_after_ltp1;
    reg [WEIGHT_BIT_WIDTH-1:0] w_n7_n0_after_ltp1;

    // General-purpose test variables
    reg [WEIGHT_BIT_WIDTH-1:0]      actual_weight;
    reg [WEIGHT_BIT_WIDTH-1:0]      expected_weight;
    reg [20:0]                      actual_trace_entry;
    reg [TRACE_VALUE_BIT_WIDTH-1:0] effective_trace;

    // =========================================================================
    // Main test body
    // =========================================================================
    initial begin
        $display("=============================================================");
        $display("  tb_neuron_cluster_v2 — 16-Neuron Integration Testbench");
        $display("  CLK_PERIOD_NS         : %0d ns",   CLK_PERIOD_NS);
        $display("  MAX_SIMULATION_CYCLES : %0d",      MAX_SIMULATION_CYCLES);
        $display("  MAX_STDP_WAIT_CYCLES  : %0d",      MAX_STDP_WAIT_CYCLES);
        $display("  NUM_NEURONS           : %0d",      NUM_NEURONS_PER_CLUSTER);
        $display("  NUM_WEIGHT_BANKS      : %0d",      NUM_WEIGHT_BANKS);
        $display("  SPIKE_QUEUE_DEPTH     : %0d",      SPIKE_QUEUE_DEPTH);
        $display("  INCREASE_MODE         : %0d (SET_MAX → post trace = 0xFF on spike)",
                 INCREASE_MODE);
        $display("=============================================================");

        // ---- Reset sequence ----
        reset                    = 1;
        global_cluster_enable    = 0;
        decay_enable_pulse       = 0;
        external_spike_input_bus = 0;
        repeat(4) @(posedge clock);
        #1;
        reset = 0;
        @(posedge clock); #1;

        // ================================================================
        // T01: After reset, cluster must be idle
        // ================================================================
        check_result(!cluster_busy_flag,
            "Cluster idle after reset");

        // ================================================================
        // SETUP PHASE — no init_weights.hex; all values written inline.
        // ================================================================

        // --- Zero-initialise all 16 banks (16 addresses each) ---
        $display("--- Setup: zero-initialising all weight banks ---");
        for (i_bank = 0; i_bank < NUM_WEIGHT_BANKS; i_bank = i_bank + 1)
            for (i_addr = 0; i_addr < (1 << WEIGHT_BANK_ADDRESS_WIDTH); i_addr = i_addr + 1)
                uut.weight_memory_inst.bank_memory[i_bank][i_addr] = 8'h00; // UPDATE PATH

        // --- Load test-case weights ---
        $display("--- Setup: loading test-case weights inline ---");
        // Group A/B: multi-input LTP (post = neuron 0)
        uut.weight_memory_inst.bank_memory[5][0] = W_N5_N0_INIT;  // W[0][5]
        uut.weight_memory_inst.bank_memory[7][0] = W_N7_N0_INIT;  // W[0][7]
        uut.weight_memory_inst.bank_memory[9][0] = W_N9_N0_INIT;  // W[0][9]
        // Group C: LTP saturation (post = neuron 8, pre = neuron 14)
        uut.weight_memory_inst.bank_memory[6][8] = W_SAT_INIT;    // W[8][14]  bank=(8+14)%16=6
        // Group D: LTD underflow (pre = neuron 12, post = neuron 6)
        uut.weight_memory_inst.bank_memory[2][6] = W_FLOOR_INIT;  // W[6][12]  bank=(6+12)%16=2
        @(posedge clock); #1;

        // --- Load pre-synaptic traces ---
        $display("--- Setup: loading trace memory entries ---");
        // Layout: {saturated_flag(1), timestamp(12), value(8)}
        uut.trace_memory_inst.trace_entries[5]  = {1'b0, 12'd0, TRACE_N5_INIT};  // UPDATE PATH
        uut.trace_memory_inst.trace_entries[7]  = {1'b0, 12'd0, TRACE_N7_INIT};  // UPDATE PATH
        uut.trace_memory_inst.trace_entries[9]  = {1'b0, 12'd0, TRACE_N9_INIT};  // UPDATE PATH
        uut.trace_memory_inst.trace_entries[14] = {1'b0, 12'd0, TRACE_N14_INIT}; // UPDATE PATH
        uut.trace_memory_inst.trace_entries[6]  = {1'b0, 12'd0, TRACE_N6_INIT};  // UPDATE PATH
        @(posedge clock); #1;

        // --- Configure connection matrix ---
        $display("--- Setup: configuring connection matrix ---");
        // Neurons 5, 7, 9 are PRE-synaptic to neuron 0 (bit[1] = 1)
        uut.connection_matrix_inst.connection_table[0][5]  = 2'b10; // UPDATE PATH
        uut.connection_matrix_inst.connection_table[0][7]  = 2'b10; // UPDATE PATH
        uut.connection_matrix_inst.connection_table[0][9]  = 2'b10; // UPDATE PATH
        // Neuron 14 is PRE-synaptic to neuron 8 (saturation test)
        uut.connection_matrix_inst.connection_table[8][14] = 2'b10; // UPDATE PATH
        // Neuron 12 is PRE-synaptic to neuron 6 (LTD underflow test, bit[0] = 1)
        uut.connection_matrix_inst.connection_table[12][6] = 2'b01; // UPDATE PATH
        @(posedge clock); #1;

        // ================================================================
        // T02-T04: Verify weight pre-load
        // ================================================================
        actual_weight = uut.weight_memory_inst.bank_memory[5][0]; // UPDATE PATH
        check_result(actual_weight === W_N5_N0_INIT,
            "Initial W[0][5] = 100 at Bank 5 Addr 0");

        actual_weight = uut.weight_memory_inst.bank_memory[7][0]; // UPDATE PATH
        check_result(actual_weight === W_N7_N0_INIT,
            "Initial W[0][7] = 80  at Bank 7 Addr 0");

        actual_weight = uut.weight_memory_inst.bank_memory[9][0]; // UPDATE PATH
        check_result(actual_weight === W_N9_N0_INIT,
            "Initial W[0][9] = 60  at Bank 9 Addr 0");

        // ================================================================
        // T05: Verify trace pre-load for neuron 5
        // ================================================================
        actual_trace_entry = uut.trace_memory_inst.trace_entries[5]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0]  === TRACE_N5_INIT &&
            actual_trace_entry[20]   === 1'b0            &&
            actual_trace_entry[19:8] === 12'd0,
            "Neuron 5 trace: value=128, timestamp=0, saturated=0");

        // ================================================================
        // GROUP A: Neuron 0 fires — LTP from three pre-synaptic inputs
        //
        //   LTP formula:  delta = pre_trace >> LTP_SHIFT_AMOUNT (=2)
        //   W[0][5]: 100 + (128>>2)=32  →  132
        //   W[0][7]:  80 + ( 96>>2)=24  →  104
        //   W[0][9]:  60 + ( 64>>2)=16  →   76
        // ================================================================
        $display("--- Group A: Neuron 0 fires (3 pre-synaptic inputs) ---");
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;

        inject_spike(4'd0);
        repeat(4) @(posedge clock); #1;

        // T06
        check_result(cluster_busy_flag,
            "cluster_busy_flag asserts after neuron 0 spike");

        // T07
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Group A STDP cycle completes within cycle budget");
        $display("       Completed in %0d cycles", wait_cycles);

        // T08 — W[0][5]
        #2;
        actual_weight   = uut.weight_memory_inst.bank_memory[5][0]; // UPDATE PATH
        expected_weight = expected_weight_after_ltp(W_N5_N0_INIT, TRACE_N5_INIT);
        w_n5_n0_after_ltp1 = expected_weight;
        check_result(actual_weight === expected_weight,
            "LTP Group A: W[0][5] 100 → 132");
        if (actual_weight !== expected_weight)
            $display("       Expected %0d, got %0d", expected_weight, actual_weight);

        // T09 — W[0][7]
        actual_weight   = uut.weight_memory_inst.bank_memory[7][0]; // UPDATE PATH
        expected_weight = expected_weight_after_ltp(W_N7_N0_INIT, TRACE_N7_INIT);
        w_n7_n0_after_ltp1 = expected_weight;
        check_result(actual_weight === expected_weight,
            "LTP Group A: W[0][7]  80 → 104");
        if (actual_weight !== expected_weight)
            $display("       Expected %0d, got %0d", expected_weight, actual_weight);

        // T10 — W[0][9]
        actual_weight   = uut.weight_memory_inst.bank_memory[9][0]; // UPDATE PATH
        expected_weight = expected_weight_after_ltp(W_N9_N0_INIT, TRACE_N9_INIT);
        check_result(actual_weight === expected_weight,
            "LTP Group A: W[0][9]  60 → 76");
        if (actual_weight !== expected_weight)
            $display("       Expected %0d, got %0d", expected_weight, actual_weight);

        // T11 — Post-synaptic trace of neuron 0 set to 0xFF (SET_MAX mode)
        actual_trace_entry = uut.trace_memory_inst.trace_entries[0]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0] === POST_TRACE_MAX &&
            actual_trace_entry[20]  === 1'b0,
            "Post-trace neuron 0: SET_MAX → 0xFF, saturated=0");
        if (actual_trace_entry[7:0] !== POST_TRACE_MAX)
            $display("       Expected 0xFF, got 0x%0h", actual_trace_entry[7:0]);

        // ================================================================
        // GROUP B: 16 decay pulses, then second spike on neuron 0.
        // Tests lazy decay: raw stored traces are unchanged in memory;
        // effective trace is computed on-demand using the delta_t.
        //
        // After 16 decay ticks (DECAY_SHIFT_LOG2=3):
        //   shift_amount = 16 >> 3 = 2
        //   N5: stored=128, 128>>2=32, correction=(128>>1)&1=0  → eff=32
        //   N7: stored= 96,  96>>2=24, correction=( 96>>1)&1=0  → eff=24
        //   LTP delta (N5): 32>>2=8   → W[0][5] = 132+8  = 140
        //   LTP delta (N7): 24>>2=6   → W[0][7] = 104+6  = 110
        // ================================================================
        $display("--- Group B: 16 decay pulses then second neuron 0 spike ---");

        // T12: Cluster idle before decay
        check_result(!cluster_busy_flag,
            "Cluster idle before decay pulses");

        // Apply 16 decay pulses
        repeat(16) begin
            decay_enable_pulse = 1;
            @(posedge clock);
            decay_enable_pulse = 0;
            @(posedge clock);
        end
        #1;

        // T13: Cluster stayed idle throughout
        check_result(!cluster_busy_flag,
            "Cluster idle throughout 16 decay pulses");

        // T14: Verify lazy decay — stored raw trace for neuron 5 is unchanged
        actual_trace_entry = uut.trace_memory_inst.trace_entries[5]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0] === TRACE_N5_INIT,
            "Neuron 5 raw trace still 128 (lazy decay: no in-place decrement)");
        $display("       Stored timestamp after 16 pulses: %0d", actual_trace_entry[19:8]);

        // Inject second spike on neuron 0
        inject_spike(4'd0);
        repeat(4) @(posedge clock); #1;

        // T15
        check_result(cluster_busy_flag,
            "cluster_busy_flag asserts after second neuron 0 spike");

        // T16
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Group B STDP cycle (decayed traces) completes within budget");
        $display("       Completed in %0d cycles", wait_cycles);

        // T17 — W[0][5] with decayed trace
        #2;
        effective_trace = compute_effective_trace(TRACE_N5_INIT, 12'd16);
        expected_weight = expected_weight_after_ltp(w_n5_n0_after_ltp1, effective_trace);
        actual_weight   = uut.weight_memory_inst.bank_memory[5][0]; // UPDATE PATH
        check_result(actual_weight === expected_weight,
            "Group B LTP: W[0][5] updated correctly with 16-tick decayed trace");
        if (actual_weight !== expected_weight)
            $display("       eff_trace(N5,16t)=%0d  Expected %0d, got %0d",
                     effective_trace, expected_weight, actual_weight);

        // T18 — W[0][7] with decayed trace
        effective_trace = compute_effective_trace(TRACE_N7_INIT, 12'd16);
        expected_weight = expected_weight_after_ltp(w_n7_n0_after_ltp1, effective_trace);
        actual_weight   = uut.weight_memory_inst.bank_memory[7][0]; // UPDATE PATH
        check_result(actual_weight === expected_weight,
            "Group B LTP: W[0][7] updated correctly with 16-tick decayed trace");
        if (actual_weight !== expected_weight)
            $display("       eff_trace(N7,16t)=%0d  Expected %0d, got %0d",
                     effective_trace, expected_weight, actual_weight);

        // ================================================================
        // GROUP C: LTP saturation test
        // W[8][14] starts at 0xFF. Neuron 8 fires; pre-trace of neuron 14 = 0xFF.
        // delta = 0xFF >> 2 = 63.  0xFF + 63 must clamp to 0xFF.
        // ================================================================
        $display("--- Group C: LTP saturation test (W[8][14] = 0xFF, trace N14 = 0xFF) ---");
        inject_spike(4'd8);
        repeat(4) @(posedge clock); #1;

        // T19
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Group C STDP cycle (saturation test) completes");
        $display("       Completed in %0d cycles", wait_cycles);

        // T20
        #2;
        actual_weight = uut.weight_memory_inst.bank_memory[6][8]; // UPDATE PATH
        check_result(
            actual_weight === 8'hFF,
            "LTP saturation: W[8][14] stays at 0xFF (no overflow past max)");
        if (actual_weight !== 8'hFF)
            $display("       Expected 0xFF, got 0x%0h", actual_weight);

        // ================================================================
        // GROUP D: LTD underflow test
        // W[6][12] starts at 0x00. Neuron 12 fires (PRE-synaptic to neuron 6).
        // Post-trace of neuron 6 = 0xFF. delta = 0xFF >> 2 = 63.
        // 0x00 - 63 must clamp to 0x00 (no unsigned wrap).
        // ================================================================
        $display("--- Group D: LTD underflow test (W[6][12] = 0x00, post trace N6 = 0xFF) ---");
        inject_spike(4'd12);
        repeat(4) @(posedge clock); #1;

        // T21
        check_result(cluster_busy_flag,
            "cluster_busy_flag asserts after neuron 12 spike (LTD path)");

        // T22
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Group D STDP cycle (LTD underflow) completes");
        $display("       Completed in %0d cycles", wait_cycles);

        // T23
        #2;
        actual_weight = uut.weight_memory_inst.bank_memory[2][6]; // UPDATE PATH
        check_result(
            actual_weight === 8'h00,
            "LTD underflow: W[6][12] stays at 0x00 (no wrap below zero)");
        if (actual_weight !== 8'h00)
            $display("       Expected 0x00, got 0x%0h", actual_weight);

        // ================================================================
        // GROUP E: 4 simultaneous spikes — neurons 1, 3, 11, 13
        // None have connections configured, so each STDP cycle only updates
        // the post-trace. The spike_input_queue must accept and serialise all
        // four spikes captured on the same clock edge. cluster_busy_flag must
        // remain high until all four are drained.
        // ================================================================
        $display("--- Group E: 4 simultaneous spikes (neurons 1, 3, 11, 13) ---");
        force uut.gen_neurons[1].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
        force uut.gen_neurons[3].neuron_inst.spike_output_wire  = 1'b1; // UPDATE PATH
        force uut.gen_neurons[11].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
        force uut.gen_neurons[13].neuron_inst.spike_output_wire = 1'b1; // UPDATE PATH
        @(posedge clock); #1;
        release uut.gen_neurons[1].neuron_inst.spike_output_wire;       // UPDATE PATH
        release uut.gen_neurons[3].neuron_inst.spike_output_wire;       // UPDATE PATH
        release uut.gen_neurons[11].neuron_inst.spike_output_wire;      // UPDATE PATH
        release uut.gen_neurons[13].neuron_inst.spike_output_wire;      // UPDATE PATH

        repeat(3) @(posedge clock); #1;

        // T24
        check_result(cluster_busy_flag,
            "Cluster busy after 4-way simultaneous spikes (queue loaded)");

        // T25
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "All 4 simultaneous spikes processed within cycle budget");
        $display("       All 4 STDP cycles drained in %0d wait cycles", wait_cycles);

        // ================================================================
        // T26: Output bus zero when no neurons are actively firing
        // ================================================================
        @(posedge clock); #1;
        check_result(
            cluster_spike_output_bus === {NUM_NEURONS_PER_CLUSTER{1'b0}},
            "cluster_spike_output_bus = 0 when all neurons are idle");

        // ================================================================
        // GROUP F: Reset mid-run — cluster returns to idle cleanly and
        // the STDP pipeline restarts without corruption.
        // ================================================================
        $display("--- Group F: Mid-run reset and clean restart ---");
        inject_spike(4'd0);        // kick off a new STDP cycle
        repeat(2) @(posedge clock);
        reset = 1;                 // assert reset mid-cycle
        repeat(3) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // T27
        check_result(!cluster_busy_flag,
            "Cluster idle after mid-run reset");

        // T28-T29: Fresh spike after reset — pipeline must restart from clean state
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;
        inject_spike(4'd0);
        repeat(4) @(posedge clock); #1;

        check_result(cluster_busy_flag,
            "Cluster busy after post-reset spike (pipeline restarted cleanly)");

        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Post-reset STDP cycle completes without hang");

        // ================================================================
        // Summary
        // ================================================================
        $display("");
        $display("=============================================================");
        $display("  FINAL RESULTS: %0d passed, %0d failed out of %0d tests",
                 pass_count, fail_count, test_num);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  FAILURES DETECTED — review [FAIL] lines above");
        $display("=============================================================");
        $finish;
    end

endmodule
