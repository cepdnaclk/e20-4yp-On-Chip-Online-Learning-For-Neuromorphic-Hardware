// =============================================================================
// Module: weight_distribution_receiver
// Description: One instance per neuron. Monitors the shared weight
//              distribution bus and captures the weight when the bus
//              addresses this specific neuron.
// Spec Reference: Section 4.13
// =============================================================================

`timescale 1ns/1ps

module weight_distribution_receiver #(
    parameter WEIGHT_BIT_WIDTH       = 8,
    parameter NEURON_ADDRESS_WIDTH   = 6,
    parameter THIS_NEURON_ADDRESS    = 0
)(
    input  wire                              clock,
    input  wire                              reset,

    // Shared distribution bus inputs
    input  wire [WEIGHT_BIT_WIDTH-1:0]       distribution_bus_weight_data,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]   distribution_bus_target_neuron_address,
    input  wire                              distribution_bus_valid,

    // Output to neuron
    output wire [WEIGHT_BIT_WIDTH-1:0]       held_weight_value,
    output wire                              held_weight_valid_flag,

    // Acknowledge from neuron
    input  wire                              weight_consumed_acknowledge
);

    reg [WEIGHT_BIT_WIDTH-1:0] held_weight_value_register;
    reg                        held_weight_valid_flag_register;

    assign held_weight_value      = held_weight_value_register;
    assign held_weight_valid_flag = held_weight_valid_flag_register;

    wire address_match = (distribution_bus_target_neuron_address == THIS_NEURON_ADDRESS[NEURON_ADDRESS_WIDTH-1:0]);

    always @(posedge clock) begin
        if (reset) begin
            held_weight_value_register      <= {WEIGHT_BIT_WIDTH{1'b0}};
            held_weight_valid_flag_register  <= 1'b0;
        end else begin
            // Capture new weight when bus addresses this neuron
            if (distribution_bus_valid && address_match) begin
                held_weight_value_register     <= distribution_bus_weight_data;
                held_weight_valid_flag_register <= 1'b1;
            end
            // Clear valid flag when neuron acknowledges consumption
            else if (weight_consumed_acknowledge) begin
                held_weight_valid_flag_register <= 1'b0;
            end
        end
    end

endmodule
