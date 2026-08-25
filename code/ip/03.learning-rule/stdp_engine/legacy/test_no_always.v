//Neuron model: Simple Leaky Integrate-and-Fire (LIF) Neuron
`timescale 1ps/1ps

module simple_LIF_Neuron_Model #(
    parameter WEIGHT_WIDTH = 8
) (
    input wire clock,
    input wire reset,
    input wire enable,
    input wire input_spike_wire,
    input wire [WEIGHT_WIDTH-1:0] synaptic_weight_wire,
    output wire spike_output_wire
);

wire internal_neuron_accumulator_enable_wire;
wire internal_neuron_counter_enable_wire;
wire internal_neuron_counter_reset_wire;
wire internal_neuron_accumulator_decay_wire;
wire [31:0] internal_neuron_accumulator_decay_value_wire;
wire [31:0] accumulator_spike_count_wire;
wire [31:0] internal_count_value_wire;
wire [31:0] internal_synaptic_weight_wire; // 32 bit extended synaptic weight wire

// Neuron Customization Registers
reg [31:0] spike_time_width_reg = 32'h00064; // 100 counts = example time window
reg [31:0] settling_time_reg = 32'h00004; // 4 counts = example value
reg [31:0] threshold_reg = 32'h00032; // 50 spikes = example value
reg [31:0] spike_threshold_accumulation_value_reg = 32'h0002; // example value
reg [31:0] decay_value_reg = 32'h0001; // example decay value

//State managing Registers
reg spike_output_reg = 1'b0;
reg within_spike_event_reg = 1'b0;
reg within_settling_time_reg = 1'b0;
reg internal_neuron_counter_enable_reg = 1'b0;
reg [31:0] spike_threshold_increase_value_reg = 32'h0000; // example value
reg decay_accumulator_enable_reg = 1'b0;
reg internal_neuron_counter_reset_reg = 1'b0;
reg accumulate_after_spike = 1'b0;

/****************Instantiating internal modules****************/
Internal_neuron_accumulator neuron_accumulator_instance_01(
    .enable(internal_neuron_accumulator_enable_wire),
    .reset(reset),
    .spike_input(input_spike_wire),
    .weight_input(internal_synaptic_weight_wire),
    .reset_due_to_spike(spike_output_wire),
    .decay_accumulator(internal_neuron_accumulator_decay_wire),
    .decay_value(internal_neuron_accumulator_decay_value_wire),
    .spike_count(accumulator_spike_count_wire)
);

Internal_neuron_counter neuron_counter_instance_01(
    .clock(clock),
    .reset(internal_neuron_counter_reset_wire),
    .enable(internal_neuron_counter_enable_wire),
    .count(internal_count_value_wire)
);

bit_extender_8_to_32 bit_extender_instance_01 (
    .input_8_bit(synaptic_weight_wire),
    .output_wire(internal_synaptic_weight_wire)
);

/****************Neuron logic - behavioral description****************/
assign internal_neuron_accumulator_enable_wire = within_spike_event_reg;
assign internal_neuron_counter_enable_wire = within_spike_event_reg;
assign spike_output_wire = spike_output_reg;
assign internal_neuron_accumulator_decay_wire = decay_accumulator_enable_reg;
assign internal_neuron_counter_reset_wire = internal_neuron_counter_reset_reg;
assign internal_neuron_accumulator_decay_value_wire = decay_value_reg;

endmodule
