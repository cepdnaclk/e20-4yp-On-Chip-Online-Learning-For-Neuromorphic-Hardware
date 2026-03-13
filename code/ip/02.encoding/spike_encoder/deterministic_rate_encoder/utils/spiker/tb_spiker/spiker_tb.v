`timescale 1ps/1ps

module spiker_tb();

    // =====================================================================
    // TESTBENCH SIGNALS
    // =====================================================================
    
    // Clock signal
    reg clock_tb = 1'b0;
    always #5 clock_tb = ~clock_tb;  // 10ps clock period
    
    // Input signals
    reg [31:0] spike_window_time_input_tb = 32'd0;
    reg spiker_enable_input_tb = 1'b0;
    
    // Output signals
    wire spike_output_tb;
    
    // Test state tracking
    integer error_count = 0;
    integer pass_count = 0;
    
    // =====================================================================
    // MODULE INSTANTIATION
    // =====================================================================
    
    spiker_module spiker_dut (
        .clock(clock_tb),
        .spike_window_time_input(spike_window_time_input_tb),
        .spiker_enable_input(spiker_enable_input_tb),
        .spike_output(spike_output_tb)
    );
    
    // =====================================================================
    // MONITOR INTERNAL SIGNALS VIA HIERARCHICAL ACCESS
    // =====================================================================
    
    wire [31:0] internal_counter_value = spiker_dut.spike_window_counter_output_wire;
    wire        internal_enable_reg    = spiker_dut.spiker_enable_reg;
    wire        internal_reset_reg     = spiker_dut.spiker_reset_reg;
    
    // =====================================================================
    // VERIFICATION TASKS
    // =====================================================================
    
    task verify_spike_output;
        input expected;
        input [255:0] test_name;
        begin
            if (spike_output_tb === expected) begin
                $display("[PASS] %0s | spike_output = %b (expected %b)", test_name, spike_output_tb, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s | spike_output = %b (expected %b)", test_name, spike_output_tb, expected);
                error_count = error_count + 1;
            end
        end
    endtask
    
    task verify_counter_value;
        input [31:0] expected;
        input [255:0] test_name;
        begin
            if (internal_counter_value === expected) begin
                $display("[PASS] %0s | counter = %0d (expected %0d)", test_name, internal_counter_value, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s | counter = %0d (expected %0d)", test_name, internal_counter_value, expected);
                error_count = error_count + 1;
            end
        end
    endtask
    
    task verify_reset_reg;
        input expected;
        input [255:0] test_name;
        begin
            if (internal_reset_reg === expected) begin
                $display("[PASS] %0s | reset_reg = %b (expected %b)", test_name, internal_reset_reg, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s | reset_reg = %b (expected %b)", test_name, internal_reset_reg, expected);
                error_count = error_count + 1;
            end
        end
    endtask
    
    task verify_enable_reg;
        input expected;
        input [255:0] test_name;
        begin
            if (internal_enable_reg === expected) begin
                $display("[PASS] %0s | enable_reg = %b (expected %b)", test_name, internal_enable_reg, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s | enable_reg = %b (expected %b)", test_name, internal_enable_reg, expected);
                error_count = error_count + 1;
            end
        end
    endtask
    
    task wait_n_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clock_tb);
            end
            #1; // Small delay after posedge to let signals settle
        end
    endtask
    
    task print_phase;
        input integer iter;
        input integer phase;
        input [255:0] description;
        begin
            $display("");
            $display("========================================================");
            $display("ITERATION %0d | PHASE %0d: %0s", iter, phase, description);
            $display("  Time         : %0t", $time);
            $display("  Inputs       : enable=%b, window=%0d", spiker_enable_input_tb, spike_window_time_input_tb);
            $display("  Outputs      : spike_output=%b", spike_output_tb);
            $display("  Internal     : counter=%0d, enable_reg=%b, reset_reg=%b",
                     internal_counter_value, internal_enable_reg, internal_reset_reg);
            $display("========================================================");
        end
    endtask
    
    task print_state;
        input [255:0] label;
        begin
            $display("  [STATE] %0s | time=%0t spike_out=%b counter=%0d en_reg=%b rst_reg=%b",
                     label, $time, spike_output_tb, internal_counter_value,
                     internal_enable_reg, internal_reset_reg);
        end
    endtask
    
    // =====================================================================
    // MAIN TESTBENCH - PHASE 1: Initial State Verification
    // =====================================================================
    
    initial begin
        // Waveform dump
        $dumpfile("spiker_waveform.vcd");
        $dumpvars(0, spiker_tb);
        
        $display("");
        $display("############################################################");
        $display("#   SPIKER MODULE TESTBENCH - Phase 1: Initial State Check  #");
        $display("############################################################");
        $display("  Clock period     : 10ps");
        $display("  Spike window time: 5 cycles (set later)");
        $display("");
        
        // =================================================================
        // PHASE 1A: Power-On State (Before Any Clock Edge)
        // =================================================================
        // INPUTS:  clock=0, spiker_enable_input=0, spike_window_time_input=0
        // EXPECTED: spike_output=0, counter=0, enable_reg=0, reset_reg=0
        // CHECK:   All outputs and internal registers are at initial values
        // =================================================================
        
        print_phase(0, 1, "Power-On Initial State");
        $display("  >> Checking register initial values before any clock edge");
        
        #1; // Tiny delay to let initial values settle
        
        verify_spike_output(1'b0,   "Phase1A: spike_output at power-on");
        verify_counter_value(32'd0, "Phase1A: counter at power-on");
        verify_enable_reg(1'b0,     "Phase1A: enable_reg at power-on");
        verify_reset_reg(1'b0,      "Phase1A: reset_reg at power-on");
        
        // =================================================================
        // PHASE 1B: First Clock Edge (Module Still Disabled)
        // =================================================================
        // INPUTS:  spiker_enable_input=0, spike_window_time_input=0
        // EXPECTED: spike_output=0, counter=0
        //           reset_reg=1 (else block sets it to 1)
        //           enable_reg=0 (else block sets it to 0)
        // CHECK:   The else block executes because spiker_enable_input=0
        //          This should assert reset and disable the counter
        // =================================================================
        
        print_phase(0, 2, "After First Clock Edge - Disabled");
        $display("  >> First posedge clock with enable=0 should trigger else block");
        
        wait_n_cycles(1);
        print_state("After 1st clock");
        
        verify_spike_output(1'b0,   "Phase1B: spike_output after 1st clock");
        verify_counter_value(32'd0, "Phase1B: counter after 1st clock");
        verify_reset_reg(1'b1,      "Phase1B: reset_reg should be 1 (else block)");
        verify_enable_reg(1'b0,     "Phase1B: enable_reg should be 0 (else block)");
        
        // =================================================================
        // PHASE 1C: Multiple Clock Cycles While Disabled
        // =================================================================
        // INPUTS:  spiker_enable_input=0 (still disabled)
        // EXPECTED: All values remain stable, no state change
        // CHECK:   System stays idle for 5 more cycles
        // =================================================================
        
        print_phase(0, 3, "Hold Disabled for 5 Cycles");
        $display("  >> Verifying system stays idle while disabled");
        
        wait_n_cycles(5);
        print_state("After 5 idle cycles");
        
        verify_spike_output(1'b0,   "Phase1C: spike_output after 5 idle cycles");
        verify_counter_value(32'd0, "Phase1C: counter stays at 0 while disabled");
        verify_reset_reg(1'b1,      "Phase1C: reset_reg stays 1 while disabled");
        verify_enable_reg(1'b0,     "Phase1C: enable_reg stays 0 while disabled");
        
        // =================================================================
        // PHASE 1D: Set Window Time Before Enable
        // =================================================================
        // INPUTS:  spike_window_time_input=5, spiker_enable_input=0
        // EXPECTED: No change in outputs (still disabled)
        // CHECK:   Setting window time alone does not trigger any activity
        // =================================================================
        
        print_phase(0, 4, "Set Window Time = 5 (Still Disabled)");
        $display("  >> Setting spike_window_time_input=5 while still disabled");
        
        spike_window_time_input_tb = 32'd5;
        
        wait_n_cycles(2);
        print_state("After setting window=5");
        
        verify_spike_output(1'b0,   "Phase1D: spike_output unchanged after window set");
        verify_counter_value(32'd0, "Phase1D: counter unchanged after window set");
        verify_reset_reg(1'b1,      "Phase1D: reset_reg unchanged after window set");
        verify_enable_reg(1'b0,     "Phase1D: enable_reg unchanged after window set");
        
        // =================================================================
        // PHASE 1 SUMMARY
        // =================================================================
        
        $display("");
        $display("############################################################");
        $display("#               PHASE 1 TEST SUMMARY                        #");
        $display("############################################################");
        $display("  Total Assertions : %0d", pass_count + error_count);
        $display("  Passed           : %0d", pass_count);
        $display("  Failed           : %0d", error_count);
        $display("");
        
        if (error_count == 0) begin
            $display("  >> PHASE 1 COMPLETE - All checks PASSED!");
            $display("  >> Ready for Phase 2: First Enable Cycle");
        end else begin
            $display("  >> PHASE 1 FAILED - Fix issues before proceeding");
        end
        
        $display("");
        $display("############################################################");
        $display("");
        
        #20;
        $finish;
    end

endmodule
