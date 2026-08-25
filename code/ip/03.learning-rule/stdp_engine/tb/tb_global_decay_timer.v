// =============================================================================
// Testbench: tb_global_decay_timer
// Tests: reset, increment, and wrap-around behavior
// =============================================================================

`timescale 1ns/1ps

module tb_global_decay_timer;

    parameter DECAY_TIMER_BIT_WIDTH = 4; // small for fast testing

    reg  clock;
    reg  reset;
    reg  decay_enable_pulse;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] decay_timer_current_value;

    global_decay_timer #(
        .DECAY_TIMER_BIT_WIDTH(DECAY_TIMER_BIT_WIDTH)
    ) uut (
        .clock(clock),
        .reset(reset),
        .decay_enable_pulse(decay_enable_pulse),
        .decay_timer_current_value(decay_timer_current_value)
    );

    // Clock generation: 10ns period
    initial clock = 0;
    always #5 clock = ~clock;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    task check;
        input [DECAY_TIMER_BIT_WIDTH-1:0] expected;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            if (decay_timer_current_value !== expected) begin
                $display("[FAIL] Test %0d: %0s — Expected %0d, Got %0d", test_num, test_name, expected, decay_timer_current_value);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] Test %0d: %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_global_decay_timer.vcd");
        $dumpvars(0, tb_global_decay_timer);

        reset = 1;
        decay_enable_pulse = 0;
        @(posedge clock); #1;

        // Test 1: Reset value should be 0
        check(0, "Reset value is 0");

        // Release reset
        reset = 0;
        @(posedge clock); #1;

        // Test 2: No pulse, value stays 0
        check(0, "No pulse, stays 0");

        // Test 3: Single pulse increments
        decay_enable_pulse = 1;
        @(posedge clock); #1;
        decay_enable_pulse = 0;
        check(1, "Single pulse increments to 1");

        // Test 4: Another pulse
        decay_enable_pulse = 1;
        @(posedge clock); #1;
        decay_enable_pulse = 0;
        check(2, "Second pulse increments to 2");

        // Test 5: Multiple consecutive pulses
        decay_enable_pulse = 1;
        @(posedge clock); #1;
        check(3, "Consecutive pulse 3");
        @(posedge clock); #1;
        check(4, "Consecutive pulse 4");
        decay_enable_pulse = 0;

        // Test 6: No pulse, holds value
        @(posedge clock); #1;
        check(4, "No pulse, holds at 4");

        // Test 7: Wrap around (4-bit wraps at 16)
        decay_enable_pulse = 1;
        repeat(12) @(posedge clock);
        #1;
        // Now should be at 4+12 = 16 = 0 (wrapped)
        check(0, "Wrap around to 0");
        decay_enable_pulse = 0;

        // Test 8: Reset during operation
        decay_enable_pulse = 1;
        @(posedge clock); #1;
        reset = 1;
        @(posedge clock); #1;
        check(0, "Reset during operation");
        reset = 0;
        decay_enable_pulse = 0;

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d tests ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
