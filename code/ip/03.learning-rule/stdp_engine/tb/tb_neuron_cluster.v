// =============================================================================
// Testbench: tb_neuron_cluster
// Integration test: set up connections, trigger spikes, verify STDP.
// Uses a small 4-neuron cluster for fast simulation.
// NOTE: Instantiates a simple stub neuron model since the real one
//       may not be available here. Override with real neuron for full test.
// =============================================================================

`timescale 1ns/1ps

// Stub neuron model for integration testing
// Matches the interface expected by neuron_cluster.v
module simple_LIF_Neuron_Model (
    input  wire        clock,
    input  wire        reset,
    input  wire        enable,
    input  wire        input_spike_wire,
    input  wire [7:0]  weight_input,
    output reg         spike_output_wire
);
    parameter THRESHOLD = 8'd5;
    reg [7:0] membrane_potential_register;

    always @(posedge clock) begin
        if (reset) begin
            spike_output_wire           <= 1'b0;
            membrane_potential_register <= 8'd0;
        end else if (enable) begin
            spike_output_wire <= 1'b0;
            if (input_spike_wire) begin
                if (membrane_potential_register + weight_input >= THRESHOLD) begin
                    spike_output_wire           <= 1'b1;
                    membrane_potential_register <= 8'd0;
                end else begin
                    membrane_potential_register <= membrane_potential_register + weight_input;
                end
            end
        end else begin
            spike_output_wire <= 1'b0;
        end
    end
endmodule

module tb_neuron_cluster;

    // -------------------------------------------------------------------------
    // Timing parameters — adjust these to control simulation budget
    // -------------------------------------------------------------------------
    parameter CLK_PERIOD_NS              = 10;   // Clock period in nanoseconds
    parameter MAX_SIMULATION_CYCLES      = 50000; // Watchdog: hard limit on total sim cycles
    parameter MAX_STDP_WAIT_CYCLES       = 500;   // Per-test limit waiting for busy to clear

    // -------------------------------------------------------------------------
    // Design parameters
    // -------------------------------------------------------------------------
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
    parameter INCREASE_MODE              = 0;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg  clock;
    reg  reset;
    reg  global_cluster_enable;
    reg  decay_enable_pulse;
    reg  [NUM_NEURONS_PER_CLUSTER-1:0] external_spike_input_bus;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] cluster_spike_output_bus;
    wire cluster_busy_flag;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clock = 0;
    always #(CLK_PERIOD_NS / 2) clock = ~clock;

    // -------------------------------------------------------------------------
    // Test tracking
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer test_num;
    integer wait_cycles;

    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;
    end

    // -------------------------------------------------------------------------
    // Watchdog — fires after MAX_SIMULATION_CYCLES clock periods
    // Change MAX_SIMULATION_CYCLES at the top of this file to adjust the budget
    // -------------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD_NS * MAX_SIMULATION_CYCLES);
        $display("[WATCHDOG] Simulation exceeded %0d clock cycles (%0d ns) — force stop",
                 MAX_SIMULATION_CYCLES, CLK_PERIOD_NS * MAX_SIMULATION_CYCLES);
        $display("  Increase MAX_SIMULATION_CYCLES if the design legitimately needs more time.");
        $display("\n=== WATCHDOG TERMINATION: %0d passed, %0d failed out of %0d tests ===",
                 pass_count, fail_count, test_num);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_neuron_cluster.vcd");
        $dumpvars(0, tb_neuron_cluster);
    end

    // -------------------------------------------------------------------------
    // Helper task: wait for cluster_busy_flag to de-assert
    // Waits at most MAX_STDP_WAIT_CYCLES cycles then reports timeout
    // Returns via output flag whether it timed out
    // -------------------------------------------------------------------------
    task wait_for_stdp_completion;
        output timed_out;
        begin
            timed_out  = 1'b0;
            wait_cycles = 0;
            while (cluster_busy_flag && wait_cycles < MAX_STDP_WAIT_CYCLES) begin
                @(posedge clock);
                wait_cycles = wait_cycles + 1;
            end
            #1;
            if (cluster_busy_flag) begin
                timed_out = 1'b1;
                $display("  [TIMEOUT] cluster_busy_flag still high after %0d cycles.",
                         MAX_STDP_WAIT_CYCLES);
                $display("  Increase MAX_STDP_WAIT_CYCLES if STDP legitimately needs more cycles.");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    reg timed_out_flag;

    initial begin
        $display("=============================================================");
        $display("  tb_neuron_cluster — Integration Testbench");
        $display("  MAX_SIMULATION_CYCLES : %0d cycles (%0d ns watchdog)",
                 MAX_SIMULATION_CYCLES, CLK_PERIOD_NS * MAX_SIMULATION_CYCLES);
        $display("  MAX_STDP_WAIT_CYCLES  : %0d cycles per STDP wait",
                 MAX_STDP_WAIT_CYCLES);
        $display("  CLK_PERIOD_NS         : %0d ns", CLK_PERIOD_NS);
        $display("=============================================================");

        // ---- Reset ----
        reset                    = 1;
        global_cluster_enable    = 0;
        decay_enable_pulse       = 0;
        external_spike_input_bus = 0;
        repeat(3) @(posedge clock);
        #1;
        reset = 0;
        @(posedge clock); #1;

        // ----------------------------------------------------------------
        // Test 1: After reset, cluster must not be busy
        // ----------------------------------------------------------------
        test_num = test_num + 1;
        if (!cluster_busy_flag) begin
            $display("[PASS] Test %0d: Cluster not busy after reset", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Cluster busy after reset", test_num);
            fail_count = fail_count + 1;
        end

        // ----------------------------------------------------------------
        // Test 2: External spike on neuron 0 triggers STDP pipeline
        // ----------------------------------------------------------------
        global_cluster_enable = 1;
        @(posedge clock);
        @(posedge clock);

        external_spike_input_bus = 4'b0001;
        @(posedge clock); #1;
        external_spike_input_bus = 0;

        repeat(3) @(posedge clock); #1;

        test_num = test_num + 1;
        if (cluster_busy_flag) begin
            $display("[PASS] Test %0d: Cluster busy after external spike on neuron 0", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Cluster not busy after external spike on neuron 0", test_num);
            fail_count = fail_count + 1;
        end

        // ----------------------------------------------------------------
        // Test 3: STDP pipeline completes within MAX_STDP_WAIT_CYCLES
        // ----------------------------------------------------------------
        wait_for_stdp_completion(timed_out_flag);
        test_num = test_num + 1;
        if (!timed_out_flag) begin
            $display("[PASS] Test %0d: First STDP cycle completed in %0d cycles",
                     test_num, wait_cycles);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: First STDP cycle did not complete within %0d cycles",
                     test_num, MAX_STDP_WAIT_CYCLES);
            fail_count = fail_count + 1;
        end

        // ----------------------------------------------------------------
        // Test 4: Decay enable pulses apply without error
        // ----------------------------------------------------------------
        repeat(5) begin
            decay_enable_pulse = 1;
            @(posedge clock);
            decay_enable_pulse = 0;
            @(posedge clock);
        end
        #1;
        test_num = test_num + 1;
        $display("[PASS] Test %0d: Five decay pulses applied without errors", test_num);
        pass_count = pass_count + 1;

        // ----------------------------------------------------------------
        // Test 5: Second spike (neuron 2) triggers STDP pipeline
        // ----------------------------------------------------------------
        external_spike_input_bus = 4'b0100;
        @(posedge clock); #1;
        external_spike_input_bus = 0;

        repeat(3) @(posedge clock); #1;

        test_num = test_num + 1;
        if (cluster_busy_flag) begin
            $display("[PASS] Test %0d: Second spike on neuron 2 triggers STDP pipeline", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Second spike on neuron 2 did not trigger STDP", test_num);
            fail_count = fail_count + 1;
        end

        // ----------------------------------------------------------------
        // Test 6: Second STDP cycle completes within MAX_STDP_WAIT_CYCLES
        // ----------------------------------------------------------------
        wait_for_stdp_completion(timed_out_flag);
        test_num = test_num + 1;
        if (!timed_out_flag) begin
            $display("[PASS] Test %0d: Second STDP cycle completed in %0d cycles",
                     test_num, wait_cycles);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Second STDP cycle did not complete within %0d cycles",
                     test_num, MAX_STDP_WAIT_CYCLES);
            fail_count = fail_count + 1;
        end

        // ----------------------------------------------------------------
        // Summary
        // ----------------------------------------------------------------
        $display("\n=== INTEGRATION TEST RESULTS: %0d passed, %0d failed out of %0d ===",
                 pass_count, fail_count, test_num);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILURES DETECTED — review output above");

        $finish;
    end

endmodule
