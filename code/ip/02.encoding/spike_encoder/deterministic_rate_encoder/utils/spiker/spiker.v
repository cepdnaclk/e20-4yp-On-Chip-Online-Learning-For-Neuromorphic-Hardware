// Assume the system is running at based on the spiker_enable_input
//Asserting it'll make the system run and de-asserting it will stop the system and reset the counters and the spike output until the next time it's asserted again.

module spiker_module (
    input wire clock,
    input wire [31:0] spike_window_time_input, // Have to define the spike time that is considering that , the clock will be counted less than one clock cycle.
    input wire spiker_enable_input, 
    output reg spike_output
);


encoder_counter spike_window_counter (
    .clock(clock),
    .reset(spike_window_counter_reset_signal_wire), // Reset signal for the spike window counter
    .enable(spike_window_counter_enable_signal_wire), // Enable the counter based on the spiker enable signal
    .count(spike_window_counter_output_wire) // Output wire for the spike window counter value
);


// Registers to manage the state of the spiker and the spike window counter
reg spiker_enable_reg = 1'b0; // Register to enable the spiker to generate the spike output
reg spiker_reset_reg = 1'b0; // Register to reset the spike window counter


// Wires to control the spiker output based on the spike window counter
wire spike_window_counter_enable_signal_wire;
wire spike_window_counter_reset_signal_wire;
wire [31:0] spike_window_counter_output_wire;


assign spike_window_counter_enable_signal_wire = spiker_enable_reg; // Enable the spike window counter when the spiker is enabled
assign spike_window_counter_reset_signal_wire = spiker_reset_reg;


    always @(posedge clock or posedge spiker_enable_input ) begin
        if (spiker_enable_input) begin

            if(spike_window_time_input > spike_window_counter_output_wire ) begin

                if(spiker_reset_reg == 1'b1) begin
                    // Release the reset signal for the spike window counter to allow it to start counting
                    spiker_reset_reg = 1'b0;
                end

                if(spiker_enable_reg == 1'b0) begin
                    // Enable the spike window counter to start counting the spike window time
                    spiker_enable_reg = 1'b1;
                end
                // Assert the spike output to high during the spike window
                spike_output = 1'b1;


            end else begin

                // Reset the spike window counter to start a new spike window
                spiker_reset_reg = 1'b1; // Assert the reset signal to reset the spike window counter

                // Disable the spiker until the next spike window starts
                spiker_enable_reg = 1'b0;

                // De-assert the spike output until the next spike window starts
                spike_output = 1'b0;
            end
        end 

        else begin

            // If the spiker enable input is low, ensure that the spiker is disabled and the spike output is de-asserted
            spiker_reset_reg = 1'b1; // Disable the spiker window counter value
            spiker_enable_reg = 1'b0; // Reset the spike window counter
            spike_output = 1'b0; // De-assert the spike output
        end 
    end
endmodule