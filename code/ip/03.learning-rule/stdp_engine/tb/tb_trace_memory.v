// =============================================================================
// Testbench: tb_trace_memory
// Tests: reset initialization, async read, sync write, same-address R/W
// =============================================================================

`timescale 1ns/1ps

module tb_trace_memory;

    parameter NUM_NEURONS_PER_CLUSTER = 4;
    parameter NEURON_ADDRESS_WIDTH    = 2;
    parameter TRACE_VALUE_BIT_WIDTH   = 8;
    parameter DECAY_TIMER_BIT_WIDTH   = 12;

    reg  clock, reset;
    reg  [NEURON_ADDRESS_WIDTH-1:0]  read_neuron_address;
    wire [TRACE_VALUE_BIT_WIDTH-1:0] read_trace_value;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] read_trace_stored_timestamp;
    wire                             read_trace_saturated_flag;
    reg                              write_enable;
    reg  [NEURON_ADDRESS_WIDTH-1:0]  write_neuron_address;
    reg  [TRACE_VALUE_BIT_WIDTH-1:0] write_trace_value;
    reg  [DECAY_TIMER_BIT_WIDTH-1:0] write_trace_stored_timestamp;
    reg                              write_trace_saturated_flag;

    trace_memory #(
        .NUM_NEURONS_PER_CLUSTER(NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH(NEURON_ADDRESS_WIDTH),
        .TRACE_VALUE_BIT_WIDTH(TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH(DECAY_TIMER_BIT_WIDTH)
    ) uut (.*);

    initial clock = 0;
    always #5 clock = ~clock;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    task check_read;
        input [TRACE_VALUE_BIT_WIDTH-1:0] exp_val;
        input [DECAY_TIMER_BIT_WIDTH-1:0] exp_ts;
        input exp_sat;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            if (read_trace_value !== exp_val || read_trace_stored_timestamp !== exp_ts || read_trace_saturated_flag !== exp_sat) begin
                $display("[FAIL] Test %0d: %0s — val=%0d(exp %0d) ts=%0d(exp %0d) sat=%b(exp %b)",
                    test_num, test_name, read_trace_value, exp_val, read_trace_stored_timestamp, exp_ts,
                    read_trace_saturated_flag, exp_sat);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] Test %0d: %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_trace_memory.vcd");
        $dumpvars(0, tb_trace_memory);

        reset = 1; write_enable = 0;
        read_neuron_address = 0;
        write_neuron_address = 0;
        write_trace_value = 0;
        write_trace_stored_timestamp = 0;
        write_trace_saturated_flag = 0;
        @(posedge clock); @(posedge clock); #1;
        reset = 0;

        // Test 1-4: After reset, all entries should have sat=1, ts=0, val=0
        read_neuron_address = 0; #1;
        check_read(0, 0, 1, "Reset: neuron 0 saturated");
        read_neuron_address = 1; #1;
        check_read(0, 0, 1, "Reset: neuron 1 saturated");
        read_neuron_address = 2; #1;
        check_read(0, 0, 1, "Reset: neuron 2 saturated");
        read_neuron_address = 3; #1;
        check_read(0, 0, 1, "Reset: neuron 3 saturated");

        // Test 5: Write neuron 1, then read (async)
        write_enable = 1;
        write_neuron_address = 1;
        write_trace_value = 8'hAB;
        write_trace_stored_timestamp = 12'd100;
        write_trace_saturated_flag = 0;
        @(posedge clock); #1;
        write_enable = 0;

        read_neuron_address = 1; #1;
        check_read(8'hAB, 12'd100, 0, "Write then async read neuron 1");

        // Test 6: Other neurons unchanged
        read_neuron_address = 0; #1;
        check_read(0, 0, 1, "Neuron 0 still at reset value");

        // Test 7: Same-address simultaneous R/W — read gets old value
        write_enable = 1;
        write_neuron_address = 2;
        write_trace_value = 8'h55;
        write_trace_stored_timestamp = 12'd200;
        write_trace_saturated_flag = 0;
        read_neuron_address = 2;
        // At this point before clock edge, read should show old value
        #1;
        check_read(0, 0, 1, "Same-addr R/W: read shows old value before clk");
        @(posedge clock); #1;
        write_enable = 0;
        // Now new value should be visible
        read_neuron_address = 2; #1;
        check_read(8'h55, 12'd200, 0, "Same-addr R/W: new value after clk");

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
