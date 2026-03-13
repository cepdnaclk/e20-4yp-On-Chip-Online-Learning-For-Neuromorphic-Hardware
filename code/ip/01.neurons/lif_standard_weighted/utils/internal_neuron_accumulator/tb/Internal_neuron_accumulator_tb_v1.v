`timescale 1ps/1ps
// =============================================================================
// Testbench : Internal_neuron_accumulator_tb_v1
// DUT       : Internal_neuron_accumulator (v3)
// Purpose   : Skeleton testbench — instantiation, helper tasks, and VCD setup.
//             Add your own test sequences in the marked section below.
// Run with  : mingw32-make run TB=Internal_neuron_accumulator_tb_v1
// =============================================================================
module Internal_neuron_accumulator_tb_v1;

    // -------------------------------------------------------------------------
    // DUT Signal Declarations
    // -------------------------------------------------------------------------
    reg         enable;
    reg         reset;
    reg         spike_input;
    reg  [31:0] weight_input;
    reg         reset_due_to_spike;
    reg         decay_accumulator;
    reg  [31:0] decay_value;

    wire [31:0] spike_count;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    Internal_neuron_accumulator dut (
        .enable              (enable),
        .reset               (reset),
        .spike_input         (spike_input),
        .weight_input        (weight_input),
        .reset_due_to_spike  (reset_due_to_spike),
        .decay_accumulator   (decay_accumulator),
        .decay_value         (decay_value),
        .spike_count         (spike_count)
    );

    // -------------------------------------------------------------------------
    // Helper Tasks
    // NOTE: The DUT is event-driven (posedge-triggered), NOT clock-based.
    //       Drive signals by pulsing them high then back to 0.
    // -------------------------------------------------------------------------

    // Hard reset the accumulator to 0
    task do_reset;
        begin
            reset = 1'b1;
            #10;
            reset = 1'b0;
            #10;
        end
    endtask

    // Send one spike (weight must be pre-loaded into weight_input)
    task apply_spike;
        begin
            spike_input = 1'b1;
            #10;
            spike_input = 1'b0;
            #10;
        end
    endtask

    // Trigger leaky decay (right-shift by decay_value bits)
    task apply_decay;
        begin
            decay_accumulator = 1'b1;
            #10;
            decay_accumulator = 1'b0;
            #10;
        end
    endtask

    // Trigger refractory-period subtraction (subtracts refactory_period_count)
    task apply_refractory_reset;
        begin
            reset_due_to_spike = 1'b1;
            #10;
            reset_due_to_spike = 1'b0;
            #10;
        end
    endtask

    // -------------------------------------------------------------------------
    // Monitor — prints spike_count whenever it changes
    // -------------------------------------------------------------------------
    initial begin
        $monitor("t=%0t ps | enable=%b | spike_in=%b | weight=%0d | decay_acc=%b | decay_val=%0d | rts=%b || spike_count=%0d",
                 $time, enable, spike_input, weight_input,
                 decay_accumulator, decay_value, reset_due_to_spike, spike_count);
    end

    // -------------------------------------------------------------------------
    // VCD Dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("Internal_neuron_accumulator_tb_v1.vcd");
        $dumpvars(0, Internal_neuron_accumulator_tb_v1);
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // --- Initialise all inputs ---
        enable             = 1'b0;
        reset              = 1'b0;
        spike_input        = 1'b0;
        weight_input       = 32'd0;
        reset_due_to_spike = 1'b0;
        decay_accumulator  = 1'b0;
        decay_value        = 32'd1;   // right-shift by 1 (divide by 2)

        #20;

        // --- Global reset ---
        do_reset;
        $display("--- After reset: spike_count = %0d (expect 0) ---", spike_count);

        // --- Enable the module ---
        enable = 1'b1;

        // =====================================================================
        // ADD YOUR TESTS BELOW
        // =====================================================================

        // Example — apply one spike with weight 10:
        //   weight_input = 32'd10;
        //   apply_spike;
        //   $display("After spike w=10 : spike_count = %0d", spike_count);

        // Test 1: Apply a spike with weight 5
        weight_input = 32'd5;
        #10;
        spike_input = 1'b1;
        #10;
        spike_input = 1'b0;
        #10;
        $display("After spike w=5 : spike_count = %0d (expect 5)", spike_count);

        // Test 2: Apply decay (should right-shift by 1, i.e. divide by 2)
        apply_decay;
        $display("After decay by 1 bit: spike_count = %0d (expect 2 or 3 depending on rounding)", spike_count);

        // Test 3: Apply refractory reset (should subtract refactory_period_count, which is 1 in this example)
        apply_refractory_reset;

        $display("After refractory reset: spike_count = %0d (expect 1 or 2 depending on previous decay result)", spike_count);

        // Test 4: Apply another spike with weight 3
        weight_input = 32'd3;
        #10;
        spike_input = 1'b1;
        #30;
        spike_input = 1'b0;
        #10;
        $display("After spike w=3 : spike_count = %0d (expect previous count + 3)", spike_count);




        // =====================================================================
        // END OF TESTS
        // =====================================================================

        #50;
        $display("=== Simulation complete. Final spike_count = %0d ===", spike_count);
        $finish;
    end

endmodule
