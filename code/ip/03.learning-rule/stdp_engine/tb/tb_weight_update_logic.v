// =============================================================================
// Testbench: tb_weight_update_logic
// Tests: LTP condition, LTD condition, saturation clamping
// =============================================================================

`timescale 1ns/1ps

module tb_weight_update_logic;

    parameter WEIGHT_BIT_WIDTH      = 8;
    parameter TRACE_VALUE_BIT_WIDTH = 8;
    parameter LTP_SHIFT_AMOUNT      = 2;
    parameter LTD_SHIFT_AMOUNT      = 2;

    reg  [TRACE_VALUE_BIT_WIDTH-1:0] pre_synaptic_trace_value;
    reg  [TRACE_VALUE_BIT_WIDTH-1:0] post_synaptic_trace_value;
    reg  [WEIGHT_BIT_WIDTH-1:0]      current_weight_value;
    wire [WEIGHT_BIT_WIDTH-1:0]      updated_weight_value;

    weight_update_logic #(
        .WEIGHT_BIT_WIDTH(WEIGHT_BIT_WIDTH),
        .TRACE_VALUE_BIT_WIDTH(TRACE_VALUE_BIT_WIDTH),
        .LTP_SHIFT_AMOUNT(LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT(LTD_SHIFT_AMOUNT)
    ) uut (.*);

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    task check;
        input [WEIGHT_BIT_WIDTH-1:0] expected;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            #1;
            if (updated_weight_value !== expected) begin
                $display("[FAIL] Test %0d: %0s — got %0d, expected %0d", test_num, test_name, updated_weight_value, expected);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] Test %0d: %0s (result=%0d)", test_num, test_name, updated_weight_value);
                pass_count = pass_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_weight_update_logic.vcd");
        $dumpvars(0, tb_weight_update_logic);

        // Test 1: LTP — pre_trace=100, weight=50 → delta=100>>2=25 → new=75
        pre_synaptic_trace_value = 100;
        post_synaptic_trace_value = 50;
        current_weight_value = 50;
        check(75, "LTP: w=50 + 100>>2=25 → 75");

        // Test 2: LTP with saturation — pre_trace=255, weight=250 → delta=63 → 250+63>255 → 255
        pre_synaptic_trace_value = 255;
        post_synaptic_trace_value = 50;
        current_weight_value = 250;
        check(255, "LTP: saturated at 255");

        // Test 3: LTD — pre_trace=0, post_trace=80, weight=100 → delta=80>>2=20 → 100-20=80
        pre_synaptic_trace_value = 0;
        post_synaptic_trace_value = 80;
        current_weight_value = 100;
        check(80, "LTD: w=100 - 80>>2=20 → 80");

        // Test 4: LTD with floor — pre_trace=0, post_trace=200, weight=10 → delta=50 → 10-50<0 → 0
        pre_synaptic_trace_value = 0;
        post_synaptic_trace_value = 200;
        current_weight_value = 10;
        check(0, "LTD: floored at 0");

        // Test 5: LTP with zero change — pre_trace=1, weight=100 → delta=1>>2=0 → 100
        pre_synaptic_trace_value = 1;
        post_synaptic_trace_value = 50;
        current_weight_value = 100;
        check(100, "LTP: small trace, no change");

        // Test 6: LTD with zero post_trace — pre_trace=0, post_trace=0, weight=100 → delta=0 → 100
        pre_synaptic_trace_value = 0;
        post_synaptic_trace_value = 0;
        current_weight_value = 100;
        check(100, "LTD: zero post_trace, no change");

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
