module rate_encoder (
    input wire clock,
    input wire reset,
    input wire enable;
    input wire [7:0] input_from_data_bus,
    output wire spike_encoded_output
);

deterministic_rate_encoder deterministic_rate_encoder_Instance_01 (
    .input_intensity_val(input_from_data_bus),
    .spike_interval_output(spike_interval_input_wire)
);

// Synaptic time counter instance
encoder_counter encoder_counter_instance_01 (
    .clock(clock),
    .reset(synap_time_counter_reset_signal_wire),
    .enable(synap_time_counter_enable_signal_wire),
    .count(synap_time_counter_output_wire)
);

// Local spike window counter instance
encoder_counter encoder_counter_instance_02 (
    .clock(clock),
    .reset(spike_counter_reset_signal_wire),
    .enable(spike_counter_enable_signal_wire),
    .count(spike_counter_output_wire)
);

bit_extender_8_to_32 bit_extender_8_to_32_instance_01 (
    .input_8_bit(spike_interval_input_wire),
    .output_wire(bit_extender_output_wire)
);

// Spiker module instance
spiker_module spiker_module_instance_01 (
    .clock(clock),
    .spike_window_time_input(spike_window_time_reg),
    .spiker_enable_input(spiker_enable_reg),
    .spike_output(spike_encoded_output)
);



// Define parameters for the rate encoder logic
reg[31:0] synap_time_window_reg = 32'h00000064; // Example time window for spike generation
reg[31:0] spike_window_time_reg = 32'h00000002; // Register to set spike window time - how much time to set for high and low spike output


// Registers to hold the current state 
reg [31:0] local_spike_window_reg = 32'h00000000; // Register to track the local spike window


//Control registers for the counters
reg synap_time_counter_enable_reg = 1'b0;
reg synap_time_counter_reset_reg = 1'b0;
reg spike_counter_enable_reg = 1'b0;
reg spike_counter_reset_reg = 1'b0;
reg spiker_enable_reg = 1'b0; // Register to enable the spiker to generate the spike output


// Define the wires and registers for the rate encoder logic
wire [7:0] spike_interval_input_wire;

//Global synapse time counter wires
wire synap_time_counter_enable_signal_wire;
wire synap_time_counter_reset_signal_wire;
wire [31:0] synap_time_counter_output_wire;



// Local spike window counter wires
wire spike_counter_enable_signal_wire;
wire spike_counter_reset_signal_wire;
wire [31:0] spike_counter_output_wire;

// bit_extender_8_to_32 output wire
wire [31:0] bit_extender_output_wire;


// Driving the control signals for the counters based on the input and the current state of the counters

// Logic to control the synaptic time counter
assign synap_time_counter_enable_signal_wire = synap_time_counter_enable_reg;
assign synap_time_counter_reset_signal_wire = synap_time_counter_reset_reg;

// Logic to control the local spike window counter
assign spike_counter_enable_signal_wire = spike_counter_enable_reg;
assign spike_counter_reset_signal_wire = spike_counter_reset_reg;


always @(posedge clock) begin

    if(enable) begin

        //Intialy checking if the counters 
        if(synap_time_window_reg == 0) begin

            // Check if the synaptic time counter reset signal is active
            if(synap_time_counter_reset_signal_wire) begin

                // Reset the synaptic time counter
                synap_time_counter_reset_reg <= 1'b0; // De-assert the reset signal after resetting

            end

            // Check if the local spike window counter reset signal is active
            if(spike_counter_reset_signal_wire) begin

                // Reset the local spike window counter
                spike_counter_reset_reg <= 1'b0; // De-assert the reset signal after resetting

            end

            // Feed the synaptic time calculated by the deterministic rate encoder to the synaptic time counter
            // Which is then extended to 32 bits by the bit extender module
            local_spike_window_reg <= bit_extender_output_wire;

            // Enable the synaptic time counter to start counting
            synap_time_counter_enable_reg <= 1'b1;

            // Enable the local spike window counter to start counting
            spike_counter_enable_reg <= 1'b1;

        end 

        // Check if the synaptic time counter has reached the synaptic time window
        if(synap_time_counter_output_wire >= synap_time_window_reg) begin

            // Reset the local spike window counter
            spike_counter_reset_reg <= 1'b1;

            // Disable the local spike window counter
            spike_counter_enable_reg <= 1'b0;

            // Reset the synaptic time counter
            synap_time_counter_reset_reg <= 1'b1;

            // Disable the synaptic time counter
            synap_time_counter_enable_reg <= 1'b0;

        end 
        else if (synap_time_counter_output_wire < synap_time_window_reg) begin

            // Check if the local spike window counter has reached the spike window time
            if(spike_counter_output_wire >= spike_window_time_reg) begin // Reached the spike window time --> have to spike

                // Reset the local spike window counter
                spike_counter_reset_reg <= 1'b1;

                // Enable the spiker
                spiker_enable_reg <= 1'b1;
            end 
        end 
    end
end






    
endmodule