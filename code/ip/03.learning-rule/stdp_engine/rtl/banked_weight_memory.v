// =============================================================================
// Module: banked_weight_memory
// Description: NUM_WEIGHT_BANKS independent synchronous SRAM arrays.
//              Supports row read (all banks at same address), column read
//              (one bank per cycle), and per-bank write operations.
// Spec Reference: Section 4.6
// =============================================================================

`timescale 1ns/1ps

module banked_weight_memory #(
    parameter NUM_WEIGHT_BANKS          = 64,
    parameter WEIGHT_BANK_ADDRESS_WIDTH = 6,
    parameter WEIGHT_BIT_WIDTH          = 8,
    parameter NEURON_ADDRESS_WIDTH      = 6
)(
    input  wire                                                 clock,
    input  wire                                                 reset,

    // Row read (all banks, same address, 1-cycle latency)
    input  wire                                                 row_read_enable,
    input  wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                 row_read_address,
    output reg  [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]         row_read_weight_data_bus,
    output reg                                                  row_read_data_valid,

    // Column read (one bank per cycle, 1-cycle latency)
    input  wire                                                 column_read_enable,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]                      column_read_pre_neuron_address,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]                      column_read_step_counter,
    output reg  [WEIGHT_BIT_WIDTH-1:0]                          column_read_weight_output,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      column_read_target_neuron_index,
    output reg                                                  column_read_data_valid,

    // Per-bank write
    input  wire [NUM_WEIGHT_BANKS-1:0]                          weight_write_enable_per_bank,
    input  wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                 weight_write_address,
    input  wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]         weight_write_data_bus
);

    // -------------------------------------------------------------------------
    // Bank storage arrays
    // -------------------------------------------------------------------------
    reg [WEIGHT_BIT_WIDTH-1:0] bank_memory [0:NUM_WEIGHT_BANKS-1][0:(2**WEIGHT_BANK_ADDRESS_WIDTH)-1];

    // Registered pipeline for column read
    reg [NEURON_ADDRESS_WIDTH-1:0] column_target_bank_index_register;
    reg [NEURON_ADDRESS_WIDTH-1:0] column_step_counter_register;

    integer bank_idx;
    integer addr_idx;

    always @(posedge clock) begin
        if (reset) begin
            row_read_data_valid    <= 1'b0;
            column_read_data_valid <= 1'b0;
            column_read_weight_output        <= {WEIGHT_BIT_WIDTH{1'b0}};
            column_read_target_neuron_index  <= {NEURON_ADDRESS_WIDTH{1'b0}};
            row_read_weight_data_bus         <= {(NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH){1'b0}};

            // Initialize all banks to 0
            for (bank_idx = 0; bank_idx < NUM_WEIGHT_BANKS; bank_idx = bank_idx + 1) begin
                for (addr_idx = 0; addr_idx < (2**WEIGHT_BANK_ADDRESS_WIDTH); addr_idx = addr_idx + 1) begin
                    bank_memory[bank_idx][addr_idx] <= {WEIGHT_BIT_WIDTH{1'b0}};
                end
            end
        end else begin
            // ---- Write (highest priority) ----
            for (bank_idx = 0; bank_idx < NUM_WEIGHT_BANKS; bank_idx = bank_idx + 1) begin
                if (weight_write_enable_per_bank[bank_idx]) begin
                    bank_memory[bank_idx][weight_write_address] <=
                        weight_write_data_bus[bank_idx*WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH];
                end
            end

            // ---- Row read ----
            if (row_read_enable) begin
                for (bank_idx = 0; bank_idx < NUM_WEIGHT_BANKS; bank_idx = bank_idx + 1) begin
                    row_read_weight_data_bus[bank_idx*WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH] <=
                        bank_memory[bank_idx][row_read_address];
                end
                row_read_data_valid <= 1'b1;
            end else begin
                row_read_data_valid <= 1'b0;
            end

            // ---- Column read ----
            if (column_read_enable) begin
                // Bank = (step + pre_neuron) mod NUM_WEIGHT_BANKS
                // Natural overflow handles mod since NUM_WEIGHT_BANKS is power of 2
                column_target_bank_index_register <= column_read_step_counter + column_read_pre_neuron_address;
                column_step_counter_register      <= column_read_step_counter;

                column_read_weight_output <=
                    bank_memory[(column_read_step_counter + column_read_pre_neuron_address) & (NUM_WEIGHT_BANKS-1)]
                               [column_read_step_counter];
                column_read_target_neuron_index <= column_read_step_counter;
                column_read_data_valid <= 1'b1;
            end else begin
                column_read_data_valid <= 1'b0;
            end
        end
    end

endmodule
