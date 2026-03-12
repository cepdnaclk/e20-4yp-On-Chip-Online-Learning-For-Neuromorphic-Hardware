// =============================================================================
// Module: cluster_connection_matrix
// Description: Stores a 2-bit connection descriptor per neuron pair.
//              Bit[1] = column_neuron is input to row_neuron (MSB).
//              Bit[0] = row_neuron outputs to column_neuron (LSB).
//              Read is registered (1-cycle latency). Write is synchronous.
// Spec Reference: Section 4.9
// =============================================================================

`timescale 1ns/1ps

module cluster_connection_matrix #(
    parameter NUM_NEURONS_PER_CLUSTER = 64,
    parameter NEURON_ADDRESS_WIDTH    = $clog2(NUM_NEURONS_PER_CLUSTER)
)(
    input  wire                                clock,
    input  wire                                reset,

    // Read port (registered output — 1-cycle latency)
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     read_row_neuron_address,
    output reg  [NUM_NEURONS_PER_CLUSTER-1:0]  row_input_connection_vector,
    output reg  [NUM_NEURONS_PER_CLUSTER-1:0]  row_output_connection_vector,
    output reg                                 row_data_valid,

    // Write port (synchronous)
    input  wire                                write_enable,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     write_row_neuron_address,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     write_column_neuron_address,
    input  wire [1:0]                          write_connection_bits
);

    // Internal storage: 2 bits per entry
    reg [1:0] connection_table [0:NUM_NEURONS_PER_CLUSTER-1][0:NUM_NEURONS_PER_CLUSTER-1];

    // Registered read
    integer col_idx;
    integer rst_row, rst_col;

    always @(posedge clock) begin
        if (reset) begin
            row_data_valid <= 1'b0;
            row_input_connection_vector  <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            row_output_connection_vector <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            for (rst_row = 0; rst_row < NUM_NEURONS_PER_CLUSTER; rst_row = rst_row + 1) begin
                for (rst_col = 0; rst_col < NUM_NEURONS_PER_CLUSTER; rst_col = rst_col + 1) begin
                    connection_table[rst_row][rst_col] <= 2'b00;
                end
            end
        end else begin
            // Registered read — data valid one cycle after address presented
            row_data_valid <= 1'b1;
            for (col_idx = 0; col_idx < NUM_NEURONS_PER_CLUSTER; col_idx = col_idx + 1) begin
                row_input_connection_vector[col_idx]  <= connection_table[read_row_neuron_address][col_idx][1];
                row_output_connection_vector[col_idx] <= connection_table[read_row_neuron_address][col_idx][0];
            end

            // Synchronous write
            if (write_enable) begin
                connection_table[write_row_neuron_address][write_column_neuron_address] <= write_connection_bits;
            end
        end
    end

endmodule
