`timescale 1ps/1ps
// =============================================================================
// Testbench : Simple_LIF_Neuron_Model_Initial_v4_tb_v1
// DUT       : simple_LIF_Neuron_Model (v4)
// Purpose   : Skeleton testbench — instantiation, helper tasks, and VCD setup.
//             Add your own test sequences in the marked section below.
// Run with  : mingw32-make run TB=Simple_LIF_Neuron_Model_Initial_v4_tb_v1
// =============================================================================
module Simple_LIF_Neuron_Model_Initial_v4_tb_v1;

    // -------------------------------------------------------------------------
    // DUT Signal Declarations
    // -------------------------------------------------------------------------
    reg         clock;
    reg         reset;
    reg         enable;
    reg         input_spike_wire;
    reg  [7:0]  synaptic_weight_wire;   // 8-bit weight

    wire        spike_output_wire;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    simple_LIF_Neuron_Model dut (
        .clock                 (clock),
        .reset                 (reset),
        .enable                (enable),
        .input_spike_wire      (input_spike_wire),
        .synaptic_weight_wire  (synaptic_weight_wire),
        .spike_output_wire     (spike_output_wire)
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    localparam CLOCK_PERIOD = 100;  // 100 ps per cycle

    initial begin
        clock = 1'b0;
        forever #(CLOCK_PERIOD/2) clock = ~clock;
    end

    // -------------------------------------------------------------------------
    // Helper Tasks
    // -------------------------------------------------------------------------

    // Hard reset the neuron
    task do_reset;
        begin
            reset = 1'b1;
            #(2 * CLOCK_PERIOD);
            reset = 1'b0;
            #(2 * CLOCK_PERIOD);
        end
    endtask

    // Wait for N clock cycles
    task wait_cycles(input integer num_cycles);
        integer i;
        begin
            for (i = 0; i < num_cycles; i = i + 1) begin
                @(posedge clock);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Monitor — prints spike_output whenever it changes
    // -------------------------------------------------------------------------
    initial begin
        $monitor("t=%0t ps | clock=%b | reset=%b | enable=%b | spike_in=%b | weight=%0d | spike_out=%b",
                 $time, clock, reset, enable, input_spike_wire, synaptic_weight_wire, spike_output_wire);
    end

    // -------------------------------------------------------------------------
    // VCD Dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("Simple_LIF_Neuron_Model_Initial_v4_tb_v1.vcd");
        $dumpvars(0, Simple_LIF_Neuron_Model_Initial_v4_tb_v1);
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // --- Initialise all inputs ---
        reset              = 1'b0;
        enable             = 1'b0;
        input_spike_wire   = 1'b0;
        synaptic_weight_wire = 8'd0;

        #(2 * CLOCK_PERIOD);

        // --- Global reset ---
        do_reset;
        $display("--- After reset: spike_output = %b (expect 0) ---", spike_output_wire);

        // --- Enable the neuron ---
        enable = 1'b1;
        wait_cycles(2);

        // =====================================================================
        // ADD YOUR TESTS BELOW
        // =====================================================================

        // Example test: Apply one spike and wait for response
        //   $display("--- Test 1: Applying input spike with weight=5 ---");
        //   apply_input_spike(8'd5);
        //   wait_cycles(100);
        //   $display("--- Waiting for neuron response ---");


        // Test 1: Apply a spike with weight 10
        $display("--- Test 1: Applying input spike with weight=10 ---");
        input_spike_wire = 1'b1;
        synaptic_weight_wire = 8'd10;
        #10;
        input_spike_wire = 1'b0;
        #100;
        $display("--- Waiting for neuron response ---");

         // Test 2: Apply a spike with weight 20
        $display("--- Test 2: Applying input spike with weight=20 ---");
        input_spike_wire = 1'b1;
        synaptic_weight_wire = 8'd20;
        #10;
        input_spike_wire = 1'b0;
        #100;
        $display("--- Waiting for neuron response ---");

        // Test 3: Apply a spike with weight 50
        $display("--- Test 3: Applying input spike with weight=50 ---");
        input_spike_wire = 1'b1;
        synaptic_weight_wire = 8'd50;
        #10;
        input_spike_wire = 1'b0;
        #100;
        $display("--- Waiting for neuron response ---");

        // =====================================================================
        // END OF TESTS
        // =====================================================================

        wait_cycles(10);
        $display("=== Simulation complete. Final spike_output = %b ===", spike_output_wire);
        $finish;
    end

endmodule
