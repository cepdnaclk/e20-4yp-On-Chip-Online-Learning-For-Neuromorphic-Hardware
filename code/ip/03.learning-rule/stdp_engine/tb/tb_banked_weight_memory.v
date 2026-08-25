// =============================================================================
// Testbench: tb_banked_weight_memory
// Tests: row read, column read, write, reset
// =============================================================================

`timescale 1ns/1ps

module tb_banked_weight_memory;

    parameter NUM_WEIGHT_BANKS          = 4;
    parameter WEIGHT_BANK_ADDRESS_WIDTH = 2;
    parameter WEIGHT_BIT_WIDTH          = 8;
    parameter NEURON_ADDRESS_WIDTH      = 2;

    reg  clock, reset;
    reg  row_read_enable;
    reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0] row_read_address;
    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] row_read_weight_data_bus;
    wire row_read_data_valid;
    reg  column_read_enable;
    reg  [NEURON_ADDRESS_WIDTH-1:0] column_read_pre_neuron_address;
    reg  [NEURON_ADDRESS_WIDTH-1:0] column_read_step_counter;
    wire [WEIGHT_BIT_WIDTH-1:0] column_read_weight_output;
    wire [NEURON_ADDRESS_WIDTH-1:0] column_read_target_neuron_index;
    wire column_read_data_valid;
    reg  [NUM_WEIGHT_BANKS-1:0] weight_write_enable_per_bank;
    reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0] weight_write_address;
    reg  [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] weight_write_data_bus;

    banked_weight_memory #(
        .NUM_WEIGHT_BANKS(NUM_WEIGHT_BANKS),
        .WEIGHT_BANK_ADDRESS_WIDTH(WEIGHT_BANK_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH(WEIGHT_BIT_WIDTH),
        .NEURON_ADDRESS_WIDTH(NEURON_ADDRESS_WIDTH)
    ) uut (.*);

    initial clock = 0;
    always #5 clock = ~clock;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    // Saved row read result
    reg [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] saved_row_data;
    reg saved_row_valid;

    // Capture row read data on valid
    always @(posedge clock) begin
        if (row_read_data_valid) begin
            saved_row_data  <= row_read_weight_data_bus;
            saved_row_valid <= 1'b1;
        end
    end

    initial begin
        $dumpfile("tb_banked_weight_memory.vcd");
        $dumpvars(0, tb_banked_weight_memory);

        reset = 1;
        row_read_enable = 0; row_read_address = 0;
        column_read_enable = 0; column_read_pre_neuron_address = 0; column_read_step_counter = 0;
        weight_write_enable_per_bank = 0; weight_write_address = 0; weight_write_data_bus = 0;
        saved_row_valid = 0;
        @(posedge clock); @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // Write known values to all banks at address 0
        // Bank 0 addr 0 = 8'h10, Bank 1 addr 0 = 8'h20, Bank 2 = 8'h30, Bank 3 = 8'h40
        weight_write_enable_per_bank = 4'b1111;
        weight_write_address = 2'd0;
        weight_write_data_bus = {8'h40, 8'h30, 8'h20, 8'h10};
        @(posedge clock); #1;
        weight_write_enable_per_bank = 0;

        // Also write bank 0 addr 1 = 8'hAA
        weight_write_enable_per_bank = 4'b0001;
        weight_write_address = 2'd1;
        weight_write_data_bus = {8'h00, 8'h00, 8'h00, 8'hAA};
        @(posedge clock); #1;
        weight_write_enable_per_bank = 0;
        @(posedge clock); #1;

        // Test 1: Row read address 0 — should return all 4 banks
        // Assert row_read_enable for one cycle, then check the next cycle while valid is high
        row_read_enable = 1;
        row_read_address = 2'd0;
        @(posedge clock); #1;
        row_read_enable = 0;
        // row_read_data_valid should be high now (one cycle after enable)
        // Check immediately
        test_num = test_num + 1;
        if (row_read_data_valid) begin
            if (row_read_weight_data_bus[7:0]   == 8'h10 &&
                row_read_weight_data_bus[15:8]  == 8'h20 &&
                row_read_weight_data_bus[23:16] == 8'h30 &&
                row_read_weight_data_bus[31:24] == 8'h40) begin
                $display("[PASS] Test %0d: Row read addr 0 correct (bank0=%h bank1=%h bank2=%h bank3=%h)",
                    test_num, row_read_weight_data_bus[7:0], row_read_weight_data_bus[15:8],
                    row_read_weight_data_bus[23:16], row_read_weight_data_bus[31:24]);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: Row read addr 0 — wrong values: bank0=%h bank1=%h bank2=%h bank3=%h",
                    test_num, row_read_weight_data_bus[7:0], row_read_weight_data_bus[15:8],
                    row_read_weight_data_bus[23:16], row_read_weight_data_bus[31:24]);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] Test %0d: Row read addr 0 — data_valid not high", test_num);
            fail_count = fail_count + 1;
        end

        @(posedge clock); #1;

        // Test 2: Column read — pre_neuron=1, step=0 → bank (0+1)%4=1, addr 0 → 0x20
        column_read_enable = 1;
        column_read_pre_neuron_address = 2'd1;
        column_read_step_counter = 2'd0;
        @(posedge clock); #1;
        column_read_enable = 0;
        // data valid should be high now
        test_num = test_num + 1;
        if (column_read_data_valid && column_read_weight_output == 8'h20 && column_read_target_neuron_index == 2'd0) begin
            $display("[PASS] Test %0d: Column read pre=1 step=0 → bank1 addr0 = 0x20", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Column read — valid=%b val=%h target=%0d",
                test_num, column_read_data_valid, column_read_weight_output, column_read_target_neuron_index);
            fail_count = fail_count + 1;
        end

        @(posedge clock); #1;

        // Test 3: Column read — pre_neuron=0, step=1 → bank (1+0)%4=1, addr 1 → should be 0 (not written)
        column_read_enable = 1;
        column_read_pre_neuron_address = 2'd0;
        column_read_step_counter = 2'd1;
        @(posedge clock); #1;
        column_read_enable = 0;
        test_num = test_num + 1;
        if (column_read_data_valid && column_read_weight_output == 8'h00) begin
            $display("[PASS] Test %0d: Column read unwritten location = 0", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Column read — valid=%b val=%h",
                test_num, column_read_data_valid, column_read_weight_output);
            fail_count = fail_count + 1;
        end

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
