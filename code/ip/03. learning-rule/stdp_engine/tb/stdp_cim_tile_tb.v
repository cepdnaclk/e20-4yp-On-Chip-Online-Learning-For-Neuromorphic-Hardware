// Filename: tb_stdp_cim_tile.v
// Description: Comprehensive testbench for STDP CIM Tile to visualize in GTKWave.

`timescale 1ns / 1ps

module tb_stdp_cim_tile;

    // --- Testbench Parameters ---
    localparam NUMBER_OF_NEURONS = 2;
    localparam WEIGHT_WIDTH = 16;
    localparam ADDRESS_WIDTH = 4;
    localparam MEMORY_WIDTH = NUMBER_OF_NEURONS * WEIGHT_WIDTH;

    // --- Testbench Signals ---
    reg clock;
    reg reset_active_low;

    reg [ADDRESS_WIDTH-1:0] input_address;
    reg input_is_valid;
    reg [NUMBER_OF_NEURONS-1:0] neuron_fire_vector;
    reg [MEMORY_WIDTH-1:0] flat_neuron_post_synaptic_traces;

    // --- Instantiating the Device Under Test (DUT) ---
    stdp_cim_tile #(
        .NUMBER_OF_NEURONS(NUMBER_OF_NEURONS),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ADDRESS_WIDTH(ADDRESS_WIDTH)
    ) dut (
        .clock(clock),
        .reset_active_low(reset_active_low),
        .input_address(input_address),
        .input_is_valid(input_is_valid),
        .neuron_fire_vector(neuron_fire_vector),
        .flat_neuron_post_synaptic_traces(flat_neuron_post_synaptic_traces)
    );

    // --- Clock Generation ---
    // 10ns clock period (100 MHz)
    initial begin
        clock = 0;
        forever #5 clock = ~clock; 
    end

    // --- VCD Dump for GTKWave ---
    integer memory_index; // Used for looping through memory addresses
    initial begin
        $dumpfile("stdp_simulation.vcd");
        // Dump all standard signals in the testbench and DUT
        $dumpvars(0, tb_stdp_cim_tile); 

        // EXPLICIT MEMORY DUMP: Standard $dumpvars ignores 2D arrays.
        // We must loop through the memory depth to expose it to GTKWave.
        for (memory_index = 0; memory_index < (1 << ADDRESS_WIDTH); memory_index = memory_index + 1) begin
            $dumpvars(0, dut.weight_memory.memory_array[memory_index]);
            $dumpvars(0, dut.pre_synaptic_trace_memory.memory_array[memory_index]);
        end
    end

    // --- Task to Simulate an Incoming Spike Event ---
    task inject_spike_event;
        input [ADDRESS_WIDTH-1:0] target_address;
        input [NUMBER_OF_NEURONS-1:0] fire_vector;
        input [MEMORY_WIDTH-1:0] post_traces;
        begin
            // Align to the falling edge to prevent setup/hold violations in TB
            @(negedge clock); 
            input_address = target_address;
            input_is_valid = 1'b1;
            neuron_fire_vector = fire_vector;
            flat_neuron_post_synaptic_traces = post_traces;
            
            @(negedge clock);
            input_is_valid = 1'b0;
            // Purposely scramble the bus after the valid cycle to prove 
            // the DUT's internal latches are working properly!
            input_address = 4'hF; 
            neuron_fire_vector = 2'b00;
            flat_neuron_post_synaptic_traces = 32'hDEADBEEF; 
        end
    endtask

    // --- Main Stimulus Block ---
    initial begin
        // 1. Initialize Inputs
        input_address = 0;
        input_is_valid = 0;
        neuron_fire_vector = 0;
        flat_neuron_post_synaptic_traces = 0;

        // 2. Apply Reset
        reset_active_low = 0;
        #20;
        reset_active_low = 1;
        #10;

        // 3. Backdoor Pre-load SRAMs with Known Values
        $display("--- PRE-LOADING SRAM ---");
        dut.weight_memory.memory_array[2] = {16'h1000, 16'h1000};
        dut.pre_synaptic_trace_memory.memory_array[2] = 16'h0000;
        
        dut.weight_memory.memory_array[3] = {16'h2000, 16'h2000};
        dut.pre_synaptic_trace_memory.memory_array[3] = 16'h0400;

        #20;

        // SCENARIO 1: Pure LTD (Depression)
        $display("--- SCENARIO 1: LTD ---");
        inject_spike_event(4'h2, 2'b00, {16'h0800, 16'h0400});
        #50; 

        // SCENARIO 2: Pure LTP (Potentiation)
        $display("--- SCENARIO 2: LTP ---");
        inject_spike_event(4'h3, 2'b11, {16'h0000, 16'h0000});
        #50;

        // SCENARIO 3: Simultaneous LTD + LTP
        $display("--- SCENARIO 3: Simultaneous Update ---");
        inject_spike_event(4'h3, 2'b11, {16'h0400, 16'h0000});
        #50;
        
        $display("--- SIMULATION COMPLETE ---");
        $finish;
    end

endmodule


