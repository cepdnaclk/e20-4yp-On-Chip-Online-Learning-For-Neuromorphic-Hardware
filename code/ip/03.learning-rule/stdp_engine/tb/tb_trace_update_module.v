// =============================================================================
// Testbench: tb_trace_update_module
// Tests: INCREASE (SET_MAX), DECAY_COMPUTE with various delta-t,
//        saturation, zero-output paths, correction bit
// =============================================================================

`timescale 1ns/1ps

module tb_trace_update_module;

    parameter TRACE_VALUE_BIT_WIDTH       = 8;
    parameter DECAY_TIMER_BIT_WIDTH       = 12;
    parameter TRACE_SATURATION_THRESHOLD  = 256;
    parameter DECAY_SHIFT_LOG2            = 3; // shift_amount = delta_t >> 3
    parameter TRACE_INCREMENT_VALUE       = 32;
    parameter INCREASE_MODE               = 0; // SET_MAX

    reg  clock, reset;
    reg  operation_start_pulse;
    reg  operation_type_select;
    reg  [TRACE_VALUE_BIT_WIDTH-1:0]  input_trace_value;
    reg  [DECAY_TIMER_BIT_WIDTH-1:0]  input_trace_stored_timestamp;
    reg  input_trace_saturated_flag;
    reg  [DECAY_TIMER_BIT_WIDTH-1:0]  decay_timer_current_value;
    wire [TRACE_VALUE_BIT_WIDTH-1:0]  result_trace_value;
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  result_trace_stored_timestamp;
    wire result_trace_saturated_flag;
    wire result_valid_pulse;
    wire module_busy_flag;

    trace_update_module #(
        .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
        .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
        .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
        .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
        .INCREASE_MODE              (INCREASE_MODE)
    ) uut (.*);

    initial clock = 0;
    always #5 clock = ~clock;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    task check_result;
        input [TRACE_VALUE_BIT_WIDTH-1:0] exp_val;
        input exp_sat;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            // Wait for result_valid_pulse
            @(posedge clock);
            while (!result_valid_pulse) @(posedge clock);
            #1;
            if (result_trace_value !== exp_val || result_trace_saturated_flag !== exp_sat) begin
                $display("[FAIL] Test %0d: %0s — val=%0d(exp %0d) sat=%b(exp %b)",
                    test_num, test_name, result_trace_value, exp_val,
                    result_trace_saturated_flag, exp_sat);
                fail_count = fail_count + 1;
            end else begin
                $display("[PASS] Test %0d: %0s (val=%0d sat=%b)", test_num, test_name, result_trace_value, result_trace_saturated_flag);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task start_op;
        input op_type;
        input [TRACE_VALUE_BIT_WIDTH-1:0] trace_val;
        input [DECAY_TIMER_BIT_WIDTH-1:0] stored_ts;
        input sat_flag;
        input [DECAY_TIMER_BIT_WIDTH-1:0] timer_val;
        begin
            @(posedge clock); #1;
            operation_start_pulse       = 1;
            operation_type_select       = op_type;
            input_trace_value           = trace_val;
            input_trace_stored_timestamp = stored_ts;
            input_trace_saturated_flag  = sat_flag;
            decay_timer_current_value   = timer_val;
            @(posedge clock); #1;
            operation_start_pulse       = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_trace_update_module.vcd");
        $dumpvars(0, tb_trace_update_module);

        reset = 1;
        operation_start_pulse = 0;
        operation_type_select = 0;
        input_trace_value = 0;
        input_trace_stored_timestamp = 0;
        input_trace_saturated_flag = 0;
        decay_timer_current_value = 0;
        @(posedge clock); @(posedge clock); #1;
        reset = 0;

        // Test 1: INCREASE (SET_MAX mode) — should produce 255, sat=0
        start_op(0, 8'd100, 12'd50, 0, 12'd60);
        check_result(8'd255, 0, "INCREASE SET_MAX: value=255");

        // Wait for module to be idle
        @(posedge clock); #1;

        // Test 2: DECAY_COMPUTE — already saturated input → zero output
        start_op(1, 8'd200, 12'd10, 1, 12'd20);
        check_result(8'd0, 1, "DECAY_COMPUTE: saturated input → zero");

        @(posedge clock); #1;

        // Test 3: DECAY_COMPUTE — delta_t >= TRACE_SATURATION_THRESHOLD → zero
        start_op(1, 8'd200, 12'd0, 0, 12'd300);
        check_result(8'd0, 1, "DECAY_COMPUTE: delta_t>=threshold → zero");

        @(posedge clock); #1;

        // Test 4: DECAY_COMPUTE — delta_t=0 (no shift) → value unchanged
        start_op(1, 8'd200, 12'd100, 0, 12'd100);
        check_result(8'd200, 0, "DECAY_COMPUTE: delta_t=0 → unchanged");

        @(posedge clock); #1;

        // Test 5: DECAY_COMPUTE — delta_t=8.  shift_amount = 8>>3 = 1.
        // value=200, shifted = 200>>1 = 100
        // correction: bit at (1-1)=0 of 200 = 200[0] = 0, so no correction
        // result = 100
        start_op(1, 8'd200, 12'd0, 0, 12'd8);
        check_result(8'd100, 0, "DECAY_COMPUTE: delta_t=8, shift=1, val=100");

        @(posedge clock); #1;

        // Test 6: DECAY_COMPUTE — delta_t=16. shift_amount = 16>>3 = 2.
        // value=200 (11001000), shifted = 200>>2 = 50 (00110010)
        // correction: bit at (2-1)=1 of 200 = 200[1] = 0, no correction
        // result = 50
        start_op(1, 8'd200, 12'd0, 0, 12'd16);
        check_result(8'd50, 0, "DECAY_COMPUTE: delta_t=16, shift=2, val=50");

        @(posedge clock); #1;

        // Test 7: DECAY_COMPUTE with correction bit
        // value = 8'b11100000 = 224, delta_t=8, shift=1
        // shifted = 224>>1 = 112
        // correction bit = 224[0] = 0, no correction → result=112
        start_op(1, 8'd224, 12'd0, 0, 12'd8);
        check_result(8'd112, 0, "DECAY_COMPUTE: val=224, shift=1 → 112");

        @(posedge clock); #1;

        // Test 8: DECAY_COMPUTE shift >= TRACE_VALUE_BIT_WIDTH → zero
        // delta_t=64, shift = 64>>3 = 8 >= 8 → zero
        start_op(1, 8'd200, 12'd0, 0, 12'd64);
        check_result(8'd0, 1, "DECAY_COMPUTE: shift>=width → zero");

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
