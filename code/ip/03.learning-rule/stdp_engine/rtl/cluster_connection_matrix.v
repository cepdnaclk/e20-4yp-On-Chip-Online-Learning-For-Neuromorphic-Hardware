// =============================================================================
// Module: cluster_connection_matrix
// Description: Per-neuron connectivity descriptors.
//
//   input_connection_rows[r][c]  = 1  ->  neuron c is PRE-synaptic to neuron r
//                                         (drives LTP/LTD when r fires)
//   output_connection_rows[r][c] = 1  ->  neuron r drives neuron c
//                                         (drives weight distribution when r fires)
//
// FIX (was P0): the read used to be REGISTERED while row_data_valid was
// asserted unconditionally on every non-reset cycle. The STDP controller
// therefore latched the connectivity of whatever row had been addressed
// previously — every spike was processed against the wrong neuron. The read
// is now purely COMBINATIONAL (this is a small register file), so the vectors
// are always consistent with read_row_neuron_address.
// Spec Reference: Section 4.9
// =============================================================================

`timescale 1ns/1ps

module cluster_connection_matrix #(
    parameter NUM_NEURONS_PER_CLUSTER = 64,
    parameter NEURON_ADDRESS_WIDTH    = $clog2(NUM_NEURONS_PER_CLUSTER)
)(
    input  wire                                clock,
    input  wire                                reset,

    // Read port (combinational — no latency)
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     read_row_neuron_address,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]  row_input_connection_vector,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]  row_output_connection_vector,
    output wire                                row_data_valid,

    // Write port (synchronous, one bit-pair per cycle)
    input  wire                                write_enable,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     write_row_neuron_address,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     write_column_neuron_address,
    input  wire [1:0]                          write_connection_bits
);

    // Storage held as one N-bit vector per row per direction. This is both
    // cheaper to read combinationally and far faster to simulate than an
    // N x N array of 2-bit entries.
    reg [NUM_NEURONS_PER_CLUSTER-1:0] input_connection_rows  [0:NUM_NEURONS_PER_CLUSTER-1];
    reg [NUM_NEURONS_PER_CLUSTER-1:0] output_connection_rows [0:NUM_NEURONS_PER_CLUSTER-1];

    assign row_input_connection_vector  = input_connection_rows [read_row_neuron_address];
    assign row_output_connection_vector = output_connection_rows[read_row_neuron_address];
    assign row_data_valid               = 1'b1;   // combinational read is always valid

    integer rst_row;
    always @(posedge clock) begin
        if (reset) begin
            for (rst_row = 0; rst_row < NUM_NEURONS_PER_CLUSTER; rst_row = rst_row + 1) begin
                input_connection_rows [rst_row] <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
                output_connection_rows[rst_row] <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            end
        end else if (write_enable) begin
            input_connection_rows [write_row_neuron_address][write_column_neuron_address]
                <= write_connection_bits[1];
            output_connection_rows[write_row_neuron_address][write_column_neuron_address]
                <= write_connection_bits[0];
        end
    end

endmodule
