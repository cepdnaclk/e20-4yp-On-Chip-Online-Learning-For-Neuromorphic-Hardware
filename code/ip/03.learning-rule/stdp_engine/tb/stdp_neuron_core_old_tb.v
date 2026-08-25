`timescale 1ns/1ps

module tb_stdp_neuron;

    // -- 1. Constants & Parameters --
    parameter DATA_WIDTH = 16;
    parameter ADDR_WIDTH = 10;
    parameter DECAY_SHIFT = 2; // Fast decay for simulation speed
    parameter MAX_WEIGHT = 16'hFFFF;

    // -- 2. Signals to Connect to DUT (Device Under Test) --
    reg clk;
    reg reset_n;
    reg post_fire;
    reg pre_spike_in;
    reg [ADDR_WIDTH-1:0] syn_addr;
    reg [DATA_WIDTH-1:0] weight_in;
    wire [DATA_WIDTH-1:0] weight_out;
    wire weight_write_enable;
    reg [DATA_WIDTH-1:0] pre_trace_in;
    wire [DATA_WIDTH-1:0] pre_trace_out;
    wire trace_write_enable;

    // -- 3. Instantiate the STDP Core --
    stdp_neuron_core #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DECAY_SHIFT(DECAY_SHIFT)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .post_fire(post_fire),
        .pre_spike_in(pre_spike_in),
        .syn_addr(syn_addr),
        .weight_in(weight_in),
        .weight_out(weight_out),
        .weight_write_enable(weight_write_enable),
        .pre_trace_in(pre_trace_in),
        .pre_trace_out(pre_trace_out),
        .trace_write_enable(trace_write_enable)
    );

    // -- 4. Clock Generation --
    initial clk = 0;
    always #5 clk = ~clk; // 100MHz clock (10ns period)

    // -- 5. Test Tasks (Helper functions) --
    
    // Reset the system
    task reset_system;
        begin
            $display("--- [Step 0] Resetting System ---");
            reset_n = 0;
            post_fire = 0;
            pre_spike_in = 0;
            syn_addr = 0;
            weight_in = 16'd1000; // Start with a base weight
            pre_trace_in = 0;
            #20;
            reset_n = 1;
            #10;
        end
    endtask

    // TEST CASE 1: LTP (Pre then Post)
    task test_ltp;
        begin
            $display("\n--- [Step 1] Testing LTP (Pre -> Post) ---");
            // A. Fire Pre-Synaptic Spike
            pre_spike_in = 1;
            syn_addr = 10'd5;     // Test Synapse #5
            #10;
            pre_spike_in = 0;
            
            // Allow 'trace' to be updated in our fake memory model
            // In real hardware, RAM handles this. Here, we emulate the loopback:
            pre_trace_in = pre_trace_out; 

            // B. Wait a short time (Delta T = 20ns)
            #20; 

            // C. Fire Post-Synaptic Spike
            post_fire = 1;
            // IMPORTANT: The hardware reads 'pre_trace_in' to calculate LTP
            // In a real loop, you'd read RAM here. We just hold the value.
            #10;
            post_fire = 0;

            // D. Check Result
            if (weight_write_enable && weight_out > 1000) 
                $display("PASS: LTP Successful. Old Weight: 1000, New Weight: %d", weight_out);
            else 
                $display("FAIL: LTP Failed. Weight did not increase. Output: %d", weight_out);
        end
    endtask

    // TEST CASE 2: LTD (Post then Pre)
    task test_ltd;
        begin
            $display("\n--- [Step 2] Testing LTD (Post -> Pre) ---");
            // Reset weight for fair test
            weight_in = 16'd1000; 
            pre_trace_in = 0; // Clear trace for this test
            #20;

            // A. Fire Post-Synaptic Spike
            post_fire = 1;
            #10;
            post_fire = 0;

            // Internal Post-Trace is now high inside DUT. 
            // B. Wait a short time
            #20;

            // C. Fire Pre-Synaptic Spike
            pre_spike_in = 1;
            syn_addr = 10'd5;
            #10; 
            pre_spike_in = 0;

            // D. Check Result
            if (weight_write_enable && weight_out < 1000) 
                $display("PASS: LTD Successful. Old Weight: 1000, New Weight: %d", weight_out);
            else 
                $display("FAIL: LTD Failed. Weight did not decrease. Output: %d", weight_out);
        end
    endtask

    // -- 6. Main Test Sequence --
    initial begin
        // Setup waveforms (For visual debugging)
        $dumpfile("build/stdp_neuron_core.vcd");
        $dumpvars(0, tb_stdp_neuron);

        // Run Tests
        reset_system();
        test_ltp();
        test_ltd();

        $display("\n--- Simulation Finished ---");
        $finish;
    end

endmodule
