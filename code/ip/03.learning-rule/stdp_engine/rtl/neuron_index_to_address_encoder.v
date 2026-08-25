// =============================================================================
// Module: neuron_index_to_address_encoder
// Description: Converts a one-hot neuron spike bus into a binary address.
//              Priority encoder — lowest-index bit wins if multiple set.
//              Entirely combinational.
// Spec Reference: Section 4.10
// =============================================================================

`timescale 1ns/1ps

module neuron_index_to_address_encoder #(
    parameter NUM_NEURONS_PER_CLUSTER = 64,
    parameter NEURON_ADDRESS_WIDTH    = $clog2(NUM_NEURONS_PER_CLUSTER)
)(
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]  one_hot_spike_input_bus,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]     binary_neuron_address_output,
    output wire                                any_spike_detected
);

    assign any_spike_detected = |one_hot_spike_input_bus;

    integer scan_index;
    always @(*) begin
        binary_neuron_address_output = {NEURON_ADDRESS_WIDTH{1'b0}};
        for (scan_index = NUM_NEURONS_PER_CLUSTER - 1; scan_index >= 0; scan_index = scan_index - 1) begin
            if (one_hot_spike_input_bus[scan_index]) begin
                binary_neuron_address_output = scan_index[NEURON_ADDRESS_WIDTH-1:0];
            end
        end
    end

endmodule
