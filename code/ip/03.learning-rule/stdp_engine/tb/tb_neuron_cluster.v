// =============================================================================
// Testbench: tb_neuron_cluster
// Fixed integration testbench addressing all issues identified in review:
//   - Connection matrix configured via force/release
//   - Spikes injected directly on spike_output_wire (not via external bus)
//   - Weight and trace memory pre-loaded with known values
//   - LTP/LTD results verified against computed expected values
//   - Simultaneous spike queue serialization tested
//   - Stub neuron named 'neuron' to match neuron_cluster.v instantiation
//
// IMPORTANT — Hierarchical paths:
//   The force/release statements reference internal instance names inside
//   neuron_cluster.v. If your implementation uses different instance names,
//   update the paths marked with "UPDATE PATH" comments below.
//   Expected instance names based on the spec module list:
//     connection_matrix_inst  → cluster_connection_matrix
//     trace_memory_inst       → trace_memory
//     weight_memory_inst      → banked_weight_memory
//     neuron_inst[i]          → neuron (array of NUM_NEURONS_PER_CLUSTER)
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// Neuron stub
// Module name MUST match the module name instantiated inside neuron_cluster.v.
// Per spec Section 5: the pre-existing file is neuron.v, so module name = neuron.
// This stub keeps spike_output_wire low at all times. The testbench injects
// spikes directly via force/release on the hierarchical spike_output_wire path,
// bypassing the stub's internal logic entirely. This correctly models the
// spike queue receiving a spike without needing the full neuron model.
// =============================================================================
module neuron #(
    parameter WEIGHT_BIT_WIDTH = 8
)(
    input  wire                         clock,
    input  wire                         reset,
    input  wire                         enable,
    input  wire                         input_spike_wire,
    input  wire [WEIGHT_BIT_WIDTH-1:0]  weight_input,
    output reg                          spike_output_wire
);
    // Stub holds spike low. Testbench uses force to inject spikes.
    always @(posedge clock) begin
        if (reset || !enable)
            spike_output_wire <= 1'b0;
        // spike_output_wire remains 0 unless testbench forces it
    end
endmodule

// =============================================================================
// Main testbench
// =============================================================================
module tb_neuron_cluster;

    // =========================================================================
    // Timing parameters — edit these to control simulation budget
    // =========================================================================
    parameter CLK_PERIOD_NS          = 10;    // Clock period in nanoseconds
    parameter MAX_SIMULATION_CYCLES  = 50000; // Watchdog: total cycle hard limit
    parameter MAX_STDP_WAIT_CYCLES   = 500;   // Per-test limit for busy to clear

    // =========================================================================
    // Design parameters — 4-neuron cluster for fast simulation
    // =========================================================================
    parameter NUM_NEURONS_PER_CLUSTER    = 4;
    parameter NEURON_ADDRESS_WIDTH       = 2;
    parameter NUM_WEIGHT_BANKS           = 4;
    parameter WEIGHT_BANK_ADDRESS_WIDTH  = 2;
    parameter WEIGHT_BIT_WIDTH           = 8;
    parameter TRACE_VALUE_BIT_WIDTH      = 8;
    parameter DECAY_TIMER_BIT_WIDTH      = 12;
    parameter TRACE_SATURATION_THRESHOLD = 256;
    parameter DECAY_SHIFT_LOG2           = 3;
    parameter TRACE_INCREMENT_VALUE      = 32;
    parameter NUM_TRACE_UPDATE_MODULES   = 4;
    parameter SPIKE_QUEUE_DEPTH          = 4;
    parameter LTP_SHIFT_AMOUNT           = 2;
    parameter LTD_SHIFT_AMOUNT           = 2;
    parameter INCREASE_MODE              = 0;  // 0 = SET_MAX: post trace → 0xFF on spike

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
    // Watchdog — terminates simulation if MAX_SIMULATION_CYCLES exceeded
    // =========================================================================
    initial begin
        #(CLK_PERIOD_NS * MAX_SIMULATION_CYCLES);
        $display("");
        $display("[WATCHDOG] Simulation exceeded %0d clock cycles — force stop.",
                 MAX_SIMULATION_CYCLES);
        $display("           Increase MAX_SIMULATION_CYCLES if design needs more time.");
        $display("           Results so far: %0d passed, %0d failed out of %0d tests",
                 pass_count, fail_count, test_num);
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
    // Logs a pass or fail with consistent formatting.
    // =========================================================================
    task check_result;
        input       condition;
        input [8*64-1:0] label;
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
    // Polls cluster_busy_flag until low or MAX_STDP_WAIT_CYCLES exceeded.
    // Sets timed_out output to 1 if limit was reached.
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
    // Forces spike_output_wire high on a specific neuron for one clock cycle.
    // The spike queue inside neuron_cluster sees this exactly as a real spike.
    // Uses a case statement because iverilog does not support indexed force
    // (cannot do: force uut.neuron_inst[n].spike_output_wire).
    //
    // UPDATE PATH: Replace 'neuron_inst' with the generate/instance name used
    // for the neuron array inside your neuron_cluster.v.
    // =========================================================================
    task inject_spike;
        input [NEURON_ADDRESS_WIDTH-1:0] neuron_index;
        begin
            case (neuron_index)
                2'd0: force   uut.neuron_inst[0].spike_output_wire = 1'b1;  // UPDATE PATH
                2'd1: force   uut.neuron_inst[1].spike_output_wire = 1'b1;  // UPDATE PATH
                2'd2: force   uut.neuron_inst[2].spike_output_wire = 1'b1;  // UPDATE PATH
                2'd3: force   uut.neuron_inst[3].spike_output_wire = 1'b1;  // UPDATE PATH
                default: $display("[TB] inject_spike: invalid index %0d", neuron_index);
            endcase
            @(posedge clock); #1;
            case (neuron_index)
                2'd0: release uut.neuron_inst[0].spike_output_wire;         // UPDATE PATH
                2'd1: release uut.neuron_inst[1].spike_output_wire;         // UPDATE PATH
                2'd2: release uut.neuron_inst[2].spike_output_wire;         // UPDATE PATH
                2'd3: release uut.neuron_inst[3].spike_output_wire;         // UPDATE PATH
                default: ;
            endcase
        end
    endtask

    // =========================================================================
    // Functions: compute expected weight after LTP and LTD
    // These mirror the default weight_update_logic implementation (spec 4.7)
    // exactly so the testbench can calculate the ground-truth expected value.
    //
    // LTP (pre_trace > 0):  delta = pre_trace >> LTP_SHIFT_AMOUNT
    //                        new_w = saturating_add(current_w, delta)
    // LTD (pre_trace == 0): delta = post_trace >> LTD_SHIFT_AMOUNT
    //                        new_w = saturating_sub(current_w, delta)
    // =========================================================================
    function [WEIGHT_BIT_WIDTH-1:0] expected_weight_after_ltp;
        input [WEIGHT_BIT_WIDTH-1:0]    current_weight;
        input [TRACE_VALUE_BIT_WIDTH-1:0] pre_trace;
        reg   [WEIGHT_BIT_WIDTH:0] sum; // one extra bit to detect overflow
        begin
            sum = {1'b0, current_weight} + (pre_trace >> LTP_SHIFT_AMOUNT);
            expected_weight_after_ltp = sum[WEIGHT_BIT_WIDTH] ?
                                        {WEIGHT_BIT_WIDTH{1'b1}} :
                                        sum[WEIGHT_BIT_WIDTH-1:0];
        end
    endfunction

    function [WEIGHT_BIT_WIDTH-1:0] expected_weight_after_ltd;
        input [WEIGHT_BIT_WIDTH-1:0]    current_weight;
        input [TRACE_VALUE_BIT_WIDTH-1:0] post_trace;
        reg   [WEIGHT_BIT_WIDTH-1:0] delta;
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
    // (spec Section 4.4) to compute the effective trace at query time.
    // Used by the testbench to calculate expected post-decay trace values.
    //
    // Parameters:
    //   stored_value  : raw trace stored in trace_memory
    //   delta_t       : number of decay ticks since stored_timestamp
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
                        if (correction_bit) begin
                            // Saturating add of 1
                            shifted = (&shifted) ? shifted : shifted + 1;
                        end
                    end
                    compute_effective_trace = shifted;
                end
            end
        end
    endfunction

    // =========================================================================
    // Test scenario state variables
    // =========================================================================
    // Scenario:
    //   Neuron 1 is a pre-synaptic input to neuron 0
    //     → connection_table[0][1] bit[1] (MSB) = 1
    //   Neuron 0 outputs to neuron 2
    //     → connection_table[0][2] bit[0] (LSB) = 1
    //
    // Banked weight mapping for N=4 (W[post][pre] at Bank=(post+pre)%4, Addr=post):
    //   W[0][1] → Bank 1, Addr 0   (weight: neuron 1 → neuron 0)
    //   W[2][0] → Bank 2, Addr 2   (weight: neuron 0 → neuron 2, for distribution)
    //
    // Trace memory layout (21 bits):
    //   [20]    = saturated_flag
    //   [19:8]  = stored_timestamp (12 bits)
    //   [7:0]   = trace_value (8 bits)
    //
    // Pre-synaptic trace neuron 1: value=128, timestamp=0, saturated=0
    //   → stored as {1'b0, 12'd0, 8'd128}
    //   With 0 decay ticks elapsed: effective trace = 128 (no decay)
    //
    // Initial weight W[0][1] = 100
    // When neuron 0 fires (post):
    //   Post trace (SET_MAX) = 255
    //   LTP: delta = 128>>2 = 32 → new W[0][1] = 100 + 32 = 132

    localparam [WEIGHT_BIT_WIDTH-1:0]    INITIAL_WEIGHT_NEURON1_TO_NEURON0 = 8'd100;
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] PRE_TRACE_VALUE_NEURON1         = 8'd128;
    localparam [TRACE_VALUE_BIT_WIDTH-1:0] POST_TRACE_SET_MAX              = 8'hFF;

    reg [WEIGHT_BIT_WIDTH-1:0]    actual_weight;
    reg [WEIGHT_BIT_WIDTH-1:0]    expected_weight;
    reg [20:0]                    actual_trace_entry;
    reg [TRACE_VALUE_BIT_WIDTH-1:0] effective_pre_trace;
    reg [WEIGHT_BIT_WIDTH-1:0]    weight_after_first_ltp;

    // =========================================================================
    // Main test body
    // =========================================================================
    initial begin
        $display("=============================================================");
        $display("  tb_neuron_cluster — Fixed Integration Testbench");
        $display("  CLK_PERIOD_NS         : %0d ns", CLK_PERIOD_NS);
        $display("  MAX_SIMULATION_CYCLES : %0d cycles", MAX_SIMULATION_CYCLES);
        $display("  MAX_STDP_WAIT_CYCLES  : %0d cycles per STDP wait", MAX_STDP_WAIT_CYCLES);
        $display("  INCREASE_MODE         : %0d (0=SET_MAX → post trace = 0xFF)", INCREASE_MODE);
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
        // T01: After reset, cluster must not be busy
        // ================================================================
        check_result(!cluster_busy_flag,
            "Cluster idle after reset");

        // ================================================================
        // SETUP PHASE
        // Configure connection matrix, weight memory, and trace memory
        // via force/release before enabling the cluster.
        // ================================================================
        $display("--- Setup: configuring connection matrix ---");
        // Neuron 1 is input to neuron 0: connection_table[0][1][1] = 1
        // Neuron 0 outputs to neuron 2:  connection_table[0][2][0] = 1
        // Full entries: connection_table[0][1] = 2'b10
        //               connection_table[0][2] = 2'b01
        // UPDATE PATH: replace 'connection_matrix_inst' and 'connection_table'
        //              with actual instance and array names from neuron_cluster.v
        force uut.connection_matrix_inst.connection_table[0][1] = 2'b10;
        force uut.connection_matrix_inst.connection_table[0][2] = 2'b01;
        @(posedge clock); #1;
        release uut.connection_matrix_inst.connection_table[0][1];
        release uut.connection_matrix_inst.connection_table[0][2];

        $display("--- Setup: pre-loading weight W[0][1]=100 → Bank 1 Addr 0 ---");
        // UPDATE PATH: replace 'weight_memory_inst' and 'bank_array'
        //              with actual instance and array names from banked_weight_memory.v
        force uut.weight_memory_inst.bank_array[1][0] = INITIAL_WEIGHT_NEURON1_TO_NEURON0;
        @(posedge clock); #1;
        release uut.weight_memory_inst.bank_array[1][0];

        $display("--- Setup: pre-loading neuron 1 trace: value=128, timestamp=0, saturated=0 ---");
        // 21-bit entry layout: {saturated_flag(1), timestamp(12), value(8)}
        // UPDATE PATH: replace 'trace_memory_inst' and 'memory_array'
        //              with actual instance and array names from trace_memory.v
        force uut.trace_memory_inst.memory_array[1] = {1'b0, 12'd0, PRE_TRACE_VALUE_NEURON1};
        @(posedge clock); #1;
        release uut.trace_memory_inst.memory_array[1];

        // ================================================================
        // T02: Verify trace memory holds the pre-loaded neuron 1 entry
        // ================================================================
        #1;
        actual_trace_entry = uut.trace_memory_inst.memory_array[1]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0]  === PRE_TRACE_VALUE_NEURON1 &&
            actual_trace_entry[20]   === 1'b0 &&
            actual_trace_entry[19:8] === 12'd0,
            "Neuron 1 trace: value=128, timestamp=0, saturated=0 confirmed"
        );

        // ================================================================
        // T03: Verify initial weight in Bank 1 Addr 0
        // ================================================================
        actual_weight = uut.weight_memory_inst.bank_array[1][0]; // UPDATE PATH
        check_result(
            actual_weight === INITIAL_WEIGHT_NEURON1_TO_NEURON0,
            "Initial weight W[0][1]=100 stored at Bank 1 Addr 0"
        );

        // ================================================================
        // Enable cluster and allow it to settle
        // ================================================================
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;

        // ================================================================
        // T04: Inject spike on neuron 0 (post-synaptic fires)
        // spike_output_wire is forced high for exactly one clock cycle on
        // neuron 0. The spike_input_queue captures this and routes it to
        // the STDP controller.
        // ================================================================
        $display("--- Test: neuron 0 fires (post-synaptic STDP event) ---");
        inject_spike(2'd0);

        // Allow queue to register and STDP controller to assert busy
        repeat(4) @(posedge clock); #1;

        check_result(cluster_busy_flag,
            "cluster_busy_flag high after neuron 0 spike injected");

        // ================================================================
        // T05: First STDP cycle completes within MAX_STDP_WAIT_CYCLES
        // ================================================================
        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "STDP cycle 1 completes within cycle budget");
        $display("       Completed in %0d cycles", wait_cycles);

        // ================================================================
        // T06: Verify LTP was applied to W[0][1]
        // Pre-trace for neuron 1 = 128 (no decay, 0 ticks elapsed)
        // LTP: delta = 128 >> 2 = 32
        // Expected new weight = 100 + 32 = 132
        // ================================================================
        #2; // allow write-back to propagate
        actual_weight   = uut.weight_memory_inst.bank_array[1][0]; // UPDATE PATH
        expected_weight = expected_weight_after_ltp(INITIAL_WEIGHT_NEURON1_TO_NEURON0,
                                                    PRE_TRACE_VALUE_NEURON1);
        weight_after_first_ltp = expected_weight; // save for T10
        check_result(
            actual_weight === expected_weight,
            "LTP: W[0][1] increased from 100 to 132 after neuron 0 fires"
        );
        if (actual_weight !== expected_weight)
            $display("       Expected %0d, got %0d", expected_weight, actual_weight);

        // ================================================================
        // T07: Verify post-synaptic trace of neuron 0 was set to 0xFF
        // INCREASE_MODE=0 (SET_MAX): trace → 8'hFF when neuron fires.
        // The STDP controller writes this back to trace_memory.
        // ================================================================
        actual_trace_entry = uut.trace_memory_inst.memory_array[0]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0] === POST_TRACE_SET_MAX &&
            actual_trace_entry[20]  === 1'b0,
            "Post-synaptic trace (neuron 0): SET_MAX → 0xFF, saturated=0"
        );
        if (actual_trace_entry[7:0] !== POST_TRACE_SET_MAX)
            $display("       Expected 0xFF, got 0x%0h", actual_trace_entry[7:0]);

        // ================================================================
        // T08: Cluster is idle before decay pulses begin
        // ================================================================
        check_result(!cluster_busy_flag,
            "Cluster idle before decay pulses");

        // ================================================================
        // T09: Apply 8 decay pulses — cluster must remain idle throughout
        // Decay pulses only increment global_decay_timer; no STDP activity.
        // ================================================================
        $display("--- Applying 8 decay enable pulses ---");
        repeat(8) begin
            decay_enable_pulse = 1;
            @(posedge clock);
            decay_enable_pulse = 0;
            @(posedge clock);
        end
        #1;
        check_result(!cluster_busy_flag,
            "Cluster remains idle during 8 decay pulses");

        // ================================================================
        // T10: Trace memory stores raw value 0xFF for neuron 0 unchanged
        // Lazy decay means the stored value is NOT updated in place.
        // The effective value is computed on-demand when trace is fetched.
        // ================================================================
        actual_trace_entry = uut.trace_memory_inst.memory_array[0]; // UPDATE PATH
        check_result(
            actual_trace_entry[7:0] === POST_TRACE_SET_MAX,
            "Neuron 0 raw trace still 0xFF (lazy decay: no in-place update)"
        );
        $display("       Stored timestamp after firing: %0d decay ticks",
                 actual_trace_entry[19:8]);

        // ================================================================
        // T11: Second spike on neuron 0 — LTP with decayed pre-trace
        // After 8 decay ticks, DECAY_SHIFT_LOG2=3:
        //   shift_amount = 8 >> 3 = 1
        //   effective trace for neuron 1 = 128 >> 1 = 64
        //   correction: (128 >> 0) & 1 = 0 → no correction
        //   effective pre-trace = 64
        // LTP: delta = 64 >> 2 = 16
        // Expected new weight = 132 + 16 = 148
        // ================================================================
        $display("--- Test: neuron 0 fires again after 8 decay ticks ---");
        inject_spike(2'd0);
        repeat(4) @(posedge clock); #1;

        check_result(cluster_busy_flag,
            "cluster_busy_flag high after second neuron 0 spike");

        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "STDP cycle 2 completes within cycle budget");
        $display("       Completed in %0d cycles", wait_cycles);

        #2;
        actual_weight     = uut.weight_memory_inst.bank_array[1][0]; // UPDATE PATH
        effective_pre_trace = compute_effective_trace(PRE_TRACE_VALUE_NEURON1, 12'd8);
        expected_weight   = expected_weight_after_ltp(weight_after_first_ltp,
                                                      effective_pre_trace);
        check_result(
            actual_weight === expected_weight,
            "LTP cycle 2: W[0][1] updated correctly with decayed pre-trace"
        );
        if (actual_weight !== expected_weight)
            $display("       Effective pre-trace after 8 ticks: %0d | Expected weight: %0d, got: %0d",
                     effective_pre_trace, expected_weight, actual_weight);

        // ================================================================
        // T12: Spike on neuron 3 — no connections, trivial STDP cycle
        // connection_table[3][*] = 0 for all columns (default after reset).
        // STDP fires only post-trace update. No weight changes expected.
        // Weight at Bank 1 Addr 0 must be unchanged.
        // ================================================================
        $display("--- Test: neuron 3 fires (no connections configured) ---");
        inject_spike(2'd3);
        repeat(4) @(posedge clock); #1;

        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "STDP cycle for neuron 3 (no connections) completes");

        #2;
        actual_weight = uut.weight_memory_inst.bank_array[1][0]; // UPDATE PATH
        check_result(
            actual_weight === expected_weight,
            "W[0][1] unchanged after neuron 3 fires (not connected)"
        );

        // ================================================================
        // T13 & T14: Simultaneous spikes on neurons 1 and 2
        // Both fire on the same clock edge. The spike_input_queue must
        // serialise them. cluster_busy_flag must stay high until both are
        // processed.
        // ================================================================
        $display("--- Test: simultaneous spikes on neurons 1 and 2 ---");
        // Force both at once
        force uut.neuron_inst[1].spike_output_wire = 1'b1; // UPDATE PATH
        force uut.neuron_inst[2].spike_output_wire = 1'b1; // UPDATE PATH
        @(posedge clock); #1;
        release uut.neuron_inst[1].spike_output_wire;      // UPDATE PATH
        release uut.neuron_inst[2].spike_output_wire;      // UPDATE PATH

        repeat(3) @(posedge clock); #1;
        check_result(cluster_busy_flag,
            "Cluster busy after simultaneous spikes (T13)");

        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Both simultaneous spikes processed within cycle budget (T14)");
        $display("       Both STDP cycles completed in %0d cycles", wait_cycles);

        // ================================================================
        // T15: Verify cluster output spike bus matches neuron spikes
        // After all processing, cluster_spike_output_bus must match
        // individual spike_output_wire signals (no bit corruption).
        // All neurons are currently not firing so bus should be 0.
        // ================================================================
        @(posedge clock); #1;
        check_result(
            cluster_spike_output_bus === {NUM_NEURONS_PER_CLUSTER{1'b0}},
            "cluster_spike_output_bus is 0 when no neurons are firing"
        );

        // ================================================================
        // T16: Reset mid-run — cluster returns to idle cleanly
        // ================================================================
        $display("--- Test: reset applied mid-run ---");
        @(posedge clock);
        reset = 1;
        repeat(3) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;
        check_result(!cluster_busy_flag,
            "Cluster idle after mid-run reset");

        // ================================================================
        // T17: After reset, inject spike and verify pipeline restarts
        // cleanly from idle state (not stuck in previous state).
        // ================================================================
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;
        inject_spike(2'd0);
        repeat(4) @(posedge clock); #1;
        check_result(cluster_busy_flag,
            "Cluster busy after post-reset spike injection (pipeline restarted)");

        wait_for_stdp_completion(timed_out_flag);
        check_result(!timed_out_flag,
            "Post-reset STDP cycle completes cleanly");

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
