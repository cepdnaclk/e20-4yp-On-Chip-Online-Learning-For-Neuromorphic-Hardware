// =============================================================================
// Testbench: weight_distribution_receiver_tb
// Tests all behavioral cases from Spec Section 4.13
// =============================================================================
`timescale 1ns/1ps

module weight_distribution_receiver_tb;

    // -------------------------------------------------------------------------
    // Parameters — match the DUT instance under test
    // -------------------------------------------------------------------------
    localparam WEIGHT_BIT_WIDTH     = 8;
    localparam NEURON_ADDRESS_WIDTH = 6;
    localparam THIS_NEURON_ADDRESS  = 5;   // DUT is neuron #5
    localparam WRONG_ADDRESS        = 12;  // An address that should never match

    localparam CLK_PERIOD = 10; // 10ns clock

    // -------------------------------------------------------------------------
    // DUT port signals
    // -------------------------------------------------------------------------
    reg                            clock;
    reg                            reset;
    reg  [WEIGHT_BIT_WIDTH-1:0]    distribution_bus_weight_data;
    reg  [NEURON_ADDRESS_WIDTH-1:0]distribution_bus_target_neuron_address;
    reg                            distribution_bus_valid;
    wire [WEIGHT_BIT_WIDTH-1:0]    held_weight_value;
    wire                           held_weight_valid_flag;
    reg                            weight_consumed_acknowledge;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    weight_distribution_receiver #(
        .WEIGHT_BIT_WIDTH     (WEIGHT_BIT_WIDTH),
        .NEURON_ADDRESS_WIDTH (NEURON_ADDRESS_WIDTH),
        .THIS_NEURON_ADDRESS  (THIS_NEURON_ADDRESS)
    ) dut (
        .clock                               (clock),
        .reset                               (reset),
        .distribution_bus_weight_data        (distribution_bus_weight_data),
        .distribution_bus_target_neuron_address(distribution_bus_target_neuron_address),
        .distribution_bus_valid              (distribution_bus_valid),
        .held_weight_value                   (held_weight_value),
        .held_weight_valid_flag              (held_weight_valid_flag),
        .weight_consumed_acknowledge         (weight_consumed_acknowledge)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clock = 0;
    always #(CLK_PERIOD/2) clock = ~clock;

    // -------------------------------------------------------------------------
    // Test tracking
    // -------------------------------------------------------------------------
    integer test_number;
    integer pass_count;
    integer fail_count;

    task automatic check;
        input [63:0]  actual_weight;
        input [63:0]  expected_weight;
        input         actual_valid;
        input         expected_valid;
        input [127:0] test_name;
        begin
            if (actual_weight === expected_weight && actual_valid === expected_valid) begin
                $display("  PASS [T%0d] %s", test_number, test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL [T%0d] %s", test_number, test_name);
                if (actual_weight !== expected_weight)
                    $display("         held_weight_value    : got %0d, expected %0d",
                             actual_weight, expected_weight);
                if (actual_valid !== expected_valid)
                    $display("         held_weight_valid_flag: got %0b, expected %0b",
                             actual_valid, expected_valid);
                fail_count = fail_count + 1;
            end
            test_number = test_number + 1;
        end
    endtask

    // Helper: one clock pulse then sample outputs
    task tick;
        begin
            @(posedge clock);
            #1; // small delay past the clock edge so registers have settled
        end
    endtask

    // -------------------------------------------------------------------------
    // Default bus state helper
    // -------------------------------------------------------------------------
    task bus_idle;
        begin
            distribution_bus_valid                  <= 0;
            distribution_bus_weight_data            <= 0;
            distribution_bus_target_neuron_address  <= 0;
            weight_consumed_acknowledge             <= 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================");
        $display("  weight_distribution_receiver Testbench");
        $display("  DUT neuron address : %0d", THIS_NEURON_ADDRESS);
        $display("=================================================");

        test_number = 0;
        pass_count  = 0;
        fail_count  = 0;

        // Initialise all inputs
        reset                                   = 1;
        distribution_bus_valid                  = 0;
        distribution_bus_weight_data            = 0;
        distribution_bus_target_neuron_address  = 0;
        weight_consumed_acknowledge             = 0;

        // ----------------------------------------------------------------
        // T0 — Reset state: held value = 0, valid = 0
        // ----------------------------------------------------------------
        tick;
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Reset: held_weight_value=0 and valid_flag=0");

        // Release reset
        @(negedge clock);
        reset = 0;

        // ----------------------------------------------------------------
        // T1 — Bus valid but WRONG address: nothing should be captured
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'hAB;
        distribution_bus_target_neuron_address  = WRONG_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Wrong address: no capture");

        // ----------------------------------------------------------------
        // T2 — Bus NOT valid, correct address: nothing should be captured
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 0;
        distribution_bus_weight_data            = 8'hAB;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Bus not valid, correct address: no capture");

        // ----------------------------------------------------------------
        // T3 — Bus valid AND correct address: weight must be captured
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'h42;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 8'h42, held_weight_valid_flag, 1,
              "Correct address + valid: weight 0x42 captured, valid=1");

        // ----------------------------------------------------------------
        // T4 — Remove bus activity: captured value must persist
        // ----------------------------------------------------------------
        @(negedge clock);
        bus_idle;
        tick;
        check(held_weight_value, 8'h42, held_weight_valid_flag, 1,
              "After bus idle: held weight persists, valid persists");

        // ----------------------------------------------------------------
        // T5 — Acknowledge consumption: valid flag must clear
        // ----------------------------------------------------------------
        @(negedge clock);
        weight_consumed_acknowledge = 1;
        tick;
        check(held_weight_value, 8'h42, held_weight_valid_flag, 0,
              "After acknowledge: valid_flag cleared, value register unchanged");

        @(negedge clock);
        weight_consumed_acknowledge = 0;

        // ----------------------------------------------------------------
        // T6 — Capture a second weight after flag was cleared
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'hFF;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 8'hFF, held_weight_valid_flag, 1,
              "Second capture after clear: weight 0xFF captured, valid=1");

        // ----------------------------------------------------------------
        // T7 — Overwrite: new weight arrives while valid flag still high
        //      Spec: overwrite held_weight_value with new data
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'h77;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 8'h77, held_weight_valid_flag, 1,
              "Overwrite while valid: weight updated to 0x77, flag stays 1");

        // ----------------------------------------------------------------
        // T8 — Simultaneous capture and acknowledge: capture wins
        //      Spec: new weight takes priority over acknowledge
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'hCC;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 1;   // both at same time
        tick;
        check(held_weight_value, 8'hCC, held_weight_valid_flag, 1,
              "Simultaneous capture+ack: capture wins, weight=0xCC, valid=1");

        @(negedge clock);
        distribution_bus_valid      = 0;
        weight_consumed_acknowledge = 0;

        // ----------------------------------------------------------------
        // T9 — Reset mid-operation: clears everything
        // ----------------------------------------------------------------
        // valid flag is still 1 from T8
        @(negedge clock);
        reset = 1;
        tick;
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Reset mid-operation: value=0, valid=0");

        @(negedge clock);
        reset = 0;

        // ----------------------------------------------------------------
        // T10 — Acknowledge with nothing captured (flag already 0): no change
        // ----------------------------------------------------------------
        @(negedge clock);
        weight_consumed_acknowledge = 1;
        tick;
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Spurious acknowledge (flag already 0): no change");

        @(negedge clock);
        weight_consumed_acknowledge = 0;

        // ----------------------------------------------------------------
        // T11 — Boundary weight value 0x00 is captured correctly
        // ----------------------------------------------------------------
        @(negedge clock);
        distribution_bus_valid                  = 1;
        distribution_bus_weight_data            = 8'h00;
        distribution_bus_target_neuron_address  = THIS_NEURON_ADDRESS;
        weight_consumed_acknowledge             = 0;
        tick;
        check(held_weight_value, 8'h00, held_weight_valid_flag, 1,
              "Boundary: weight 0x00 captured, valid=1");

        // ----------------------------------------------------------------
        // T12 — Multiple wrong addresses in a row: still no capture
        // ----------------------------------------------------------------

        @(negedge clock);
        bus_idle;                        // <-- deassert distribution_bus_valid first
        tick;

        @(negedge clock);
        weight_consumed_acknowledge = 1; // now safe to acknowledge — no competing capture
        tick;
        @(negedge clock);
        weight_consumed_acknowledge = 0;

        begin : multi_wrong_addr_block
            integer addr_idx;
            for (addr_idx = 0; addr_idx < 4; addr_idx = addr_idx + 1) begin
                @(negedge clock);
                distribution_bus_valid                  = 1;
                distribution_bus_weight_data            = 8'hDE;
                distribution_bus_target_neuron_address  = (THIS_NEURON_ADDRESS + addr_idx + 1)
                                                          % (1 << NEURON_ADDRESS_WIDTH);
                weight_consumed_acknowledge             = 0;
                tick;
            end
        end
        check(held_weight_value, 0, held_weight_valid_flag, 0,
              "Four consecutive wrong addresses: no capture at any step");

        // ----------------------------------------------------------------
        // Final result
        // ----------------------------------------------------------------
        #20;
        $display("=================================================");
        $display("  Results: %0d passed, %0d failed out of %0d tests",
                 pass_count, fail_count, test_number);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED — review output above");
        $display("=================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog — catches infinite loops or hangs
    // -------------------------------------------------------------------------
    initial begin
        #5000;
        $display("WATCHDOG: simulation timeout — possible hang");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Optional waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("weight_distribution_receiver_tb.vcd");
        $dumpvars(0, weight_distribution_receiver_tb);
    end

endmodule
