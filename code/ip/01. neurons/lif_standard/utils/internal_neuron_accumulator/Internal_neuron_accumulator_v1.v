//Accumilating spikes
`timescale 1ps/1ps
module Internal_neuron_accumulator
( 
    input wire enable,
    input wire reset,
    input wire spike_input,
    output wire [31:0] spike_count,
    input wire reset_due_to_spike,
    input wire decay_accumulator,
    input wire [31:0] decay_value
);

// Defining Refactory period in terms of spike count
reg [31:0] refactory_period_count = 32'h000A; // example value

// Spike count register
reg [31:0] spike_count_reg = 32'b0;

// Decay value register
reg [31:0] decay_value_reg = 32'h0000; // example decay value

// Assigning output
assign spike_count = spike_count_reg;

// Assing the decal value to decay register
//assign decay_value_reg = decay_value;


// // Spike input logic
// always @(posedge spike_input) begin
    
//     if(enable) begin
//         spike_count_reg <= spike_count_reg + 1;
//     end

// end

// // Reset logic
// always @(posedge reset) begin
//     // Set to 1 on reset - As with current implementation, first spike will be missed otherwise
//     spike_count_reg = 32'b0000_0000_0000_0000_0000_0000_0000_0001;
// end

// // Reset due to spike logic
// always @(posedge reset_due_to_spike) begin
//     //Reset due to spike - subtract refactory period
//     //Nedd to handle underflow
//     spike_count_reg = spike_count_reg - refactory_period_count;
// end

// // Decay logic
// always @(posedge decay_accumulator) begin
//     //Shift right to decay - simple decay implementation
//     spike_count_reg = spike_count_reg>>1; // example decay by half
// end



always @(posedge spike_input or posedge reset or posedge reset_due_to_spike or posedge decay_accumulator) begin

    if (reset) begin
        // Set to 1 on reset - As with current implementation, first spike will be missed otherwise
        spike_count_reg = 32'b0000_0000_0000_0000_0000_0000_0000_0001;

    end

    //Check for the enable signal
    else if (enable) begin

        //We have 8 different conditions to check for check with various combinations of spike_input, reset_due_to_spike and decay_accumulator
        // 01.spike_input = 0, reset_due_to_spike = 0, decay_accumulator = 0
        // No action needed

        // 02.spike_input = 0, reset_due_to_spike = 0, decay_accumulator = 1 --> No input spiike but accumulated value needs to be decayed
        if (spike_input == 0 && reset_due_to_spike  == 0 && decay_accumulator == 1) begin
            //Decay accumulator - shift right
            spike_count_reg <= spike_count_reg>>decay_value; // example decay by half
        end

        // 03.spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 0 --> No input spike but need to reset due to spike - But highly unlikely to happen, assume if there's any dalay in fpga cause to trigger this or this was implemented
        else if (spike_input == 0 && reset_due_to_spike  == 1 && decay_accumulator == 0) begin
            //Reset due to spike - subtract refactory period
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0; // Here it is set to zero since the neuron is in running state
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end
        end

        // 04.spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 1 --> No input spike but need to reset due to spike and decay accumulator - But highly unlikely to happen, assume if there's any dalay in fpga cause to trigger this or this was implemented
        else if (spike_input == 0 && reset_due_to_spike  == 1 && decay_accumulator == 1) begin
            //Reset due to spike - subtract refactory period
            // Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0; // Here it is set to zero since the neuron is in running state
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            //Decay accumulator - shift right
            spike_count_reg = spike_count_reg>>decay_value; // example decay by half

        end

        // 05.spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 0 --> Normal spike input
        else if(spike_input == 1 && reset_due_to_spike  == 0 && decay_accumulator == 0) begin
            spike_count_reg = spike_count_reg + 1;
        end

        // 06.spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 1 --> Spike input and decay accumulator
        else if (spike_input == 1 && reset_due_to_spike  == 0 && decay_accumulator == 1) begin
            // Initially decay accumulator
            spike_count_reg = spike_count_reg>>decay_value; // decay by half

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end
        

        // 07.spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 0 --> Spike input and reset due to spike
        else if (spike_input == 1 && reset_due_to_spike  == 1 && decay_accumulator == 0) begin
            //Reset due to spike - subtract refactory period
            //Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0;
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end

        // 08.spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 1 --> Spike input, reset due to spike and decay accumulator
        else if (spike_input == 1 && reset_due_to_spike  == 1 && decay_accumulator == 1) begin
            // Initially decay accumulator
            spike_count_reg = spike_count_reg>>decay_value; // decay by half

            //Reset due to spike - subtract refactory period
            //Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0;
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end
    end
end
endmodule

