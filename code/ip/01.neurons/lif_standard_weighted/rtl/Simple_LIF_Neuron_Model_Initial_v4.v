//Neuron model: Simple Leaky Integrate-and-Fire (LIF) Neuron
`timescale 1ps/1ps
// `include "internal_neuron_accumulator.v"
// `include "internal_neuron_counter.v"


// Parameters for the neuron model

// Parameter for synaptic weight width
parameter WEIGHT_WIDTH = 8;



module simple_LIF_Neuron_Model (
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

//creating constant value reg to compare spike time width - with hex value
reg [31:0] spike_time_width_reg = 32'h00064; // 100 counts = example time window
// Creting a settling time for the neuron after time window
reg [31:0] settling_time_reg = 32'h00004; // 4 counts = example value
// Creating constant value reg for threshold
reg [31:0] threshold_reg = 32'h00032; // 50 spikes = example value
// Threshold Accumulation value register
reg [31:0] spike_threshold_accumulation_value_reg = 32'h0002; // example value
// Decay value register
reg [31:0] decay_value_reg = 32'h0001; // example decay value




//State managing Registers

//State variable - output spike
reg spike_output_reg = 1'b0;
//State variable to indicate if within spike event
reg within_spike_event_reg = 1'b0;
// State to manage the settling of the neuron after time window
reg within_settling_time_reg = 1'b0;
// Enable counter for spike time window
reg internal_neuron_counter_enable_reg = 1'b0;
//Spike Threshhold increasing value reg
reg [31:0] spike_threshold_increase_value_reg = 32'h0000; // example value
//Decay accumulator enable reg
reg decay_accumulator_enable_reg = 1'b0;

//Register for resetting internal counter
reg internal_neuron_counter_reset_reg = 1'b0;
// Accumulation after spike register
reg accumulate_after_spike = 1'b0;



/****************Instantiating internal modules****************/

// Instance of internal neuron accumulator
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

// Instance of internal neuron counter
Internal_neuron_counter neuron_counter_instance_01(
    .clock(clock),
    .reset(internal_neuron_counter_reset_wire),
    .enable(internal_neuron_counter_enable_wire),
    .count(internal_count_value_wire)
);


// 8 bit to 32 bit extender instance for synaptic weight
bit_extender_8_to_32 bit_extender_instance_01 (
    .input_8_bit(synaptic_weight_wire),
    .output_wire(internal_synaptic_weight_wire)
);


/****************Neuron logic - behavioral description****************/


// Enable logic for internal neuron accumulator - assign to wire at every change in register
assign internal_neuron_accumulator_enable_wire = within_spike_event_reg;

// Enable logic for internal neuron counter - assign to wire at every change in register
assign internal_neuron_counter_enable_wire = within_spike_event_reg;

// Enable output for spike output - assign to wire at every change in register
assign spike_output_wire = spike_output_reg;

// Enable logic for decay of accumulator
assign internal_neuron_accumulator_decay_wire = decay_accumulator_enable_reg;


// Enable logic for resetting internal counter
assign internal_neuron_counter_reset_wire = internal_neuron_counter_reset_reg;

// Drriving the neuron decay value
assign internal_neuron_accumulator_decay_value_wire = decay_value_reg;


// We need to use always block to monitor input spikes and internal counter clock pulse
// Because to initiate we need a spike.
// Also we need to monitor the time frame within the spike window - for that we use internal counter value 
//always @(posedge input_spike_wire or posedge internal_count_value_wire  ) begin
always @( posedge clock or posedge reset or posedge input_spike_wire) begin

    // Neuron enabled - Open to use the neuron
    if(enable) begin

        // Reset condition
        if (reset) begin
            //Reset all state variables
            spike_output_reg <= 1'b0;
            within_spike_event_reg <= 1'b0;
            within_settling_time_reg <= 1'b0;
            threshold_reg <= 32'h000A; // reset to initial threshold
            spike_threshold_increase_value_reg <= 32'h0000; // reset increase value
            internal_neuron_counter_reset_reg <= 1'b1; // reset internal counter
            accumulate_after_spike <= 1'b0;
        end

        else  begin
            //Spike received or clock pulse
        
                //0.0 This state is when the initial spike is received - Time window is initially not active, and at end of time window we will change the state variables
                
                if(within_spike_event_reg == 1'b0 && within_settling_time_reg== 1'b0) begin
                    //Not within spike event - start new spike event
                    within_spike_event_reg <= 1'b1;
                    //Revert the internal counter
                    internal_neuron_counter_reset_reg <= 1'b0;
                end

                //Within spike event
                
                //1.0 Before ending time window, check if threshold reached - it seems some parts are redundant - we can simply change the threshhold reg directly
                if((accumulator_spike_count_wire >= threshold_reg) && within_settling_time_reg == 1'b0 && within_spike_event_reg == 1'b1) begin
                    //Threshold reached - generate output spike
                    spike_output_reg = 1'b1;
                    //Updating the threshold to a high value to prevent learning same information 
                    spike_threshold_increase_value_reg = spike_threshold_increase_value_reg + spike_threshold_accumulation_value_reg;
                    threshold_reg = threshold_reg + spike_threshold_increase_value_reg;
                    // Reseting the mebran potential by resetting the spike count
                    //as spike_output_reg is connected to reset_due_to_spike of accumulator - it will reset 


                    // Managing the accumulation
                    if(accumulate_after_spike) begin
                        // Doing nothing

                    end else begin

                        // Disabling the accumulator
                    end 
                end

   
                //2.0 Before ending time window, threshold not reached - do nothing


                //3.0 Time window has ended
                if ((internal_count_value_wire >= spike_time_width_reg) && within_spike_event_reg == 1'b1 && within_settling_time_reg == 1'b0) begin
                    //Time window ended - reset state variables
                    within_spike_event_reg <= 1'b0;

                    if(spike_output_reg == 1'b1) begin
                        //If output spike was generated, reset it
                        spike_output_reg <= 1'b0;
                    end
                    
                    //Reset internal counter
                    internal_neuron_counter_reset_reg <= 1'b1;
                    //Adding some delay to reset signal
                    // #5;
                    // internal_neuron_counter_reset_reg = 1'b0;

                    within_settling_time_reg <= 1'b1;
                end


                //4.0 Settling time management
                if (internal_count_value_wire >= (spike_time_width_reg + settling_time_reg) && within_settling_time_reg == 1'b1) begin
                    //Settling time ended - reset state variables
                    within_settling_time_reg <= 1'b0;

                    //Decaying the membran potential by reducing the threshold
                    decay_accumulator_enable_reg <= 1'b1;

                    //Reset internal counter
                    internal_neuron_counter_reset_reg <= 1'b0;
                    //Adding some delay to reset signal
                    // #5;
                    // internal_neuron_counter_reset_reg = 1'b0;
                end

            end
    end
end

endmodule