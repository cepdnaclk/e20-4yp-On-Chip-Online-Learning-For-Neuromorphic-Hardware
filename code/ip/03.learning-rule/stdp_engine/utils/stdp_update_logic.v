// Filename: stdp_update_logic.v
// Description: Pure Combinational Logic for STDP.

module stdp_update_logic #(
    parameter WEIGHT_WIDTH = 16,
    parameter MAXIMUM_WEIGHT = 16'h7FFF
)(
    input  wire [WEIGHT_WIDTH-1:0] input_weight,
    input  wire [WEIGHT_WIDTH-1:0] pre_synaptic_trace,
    input  wire [WEIGHT_WIDTH-1:0] post_synaptic_trace,
    input  wire                    pre_synaptic_spike_is_valid, 
    input  wire                    post_synaptic_neuron_fire,
    
    output reg  [WEIGHT_WIDTH-1:0] output_weight
);

    reg [WEIGHT_WIDTH-1:0] intermediate_depressed_weight; // Added to prevent combinational loops

    always @(*) begin
        // --- LTD (Depression) Phase ---
        // Input spiked, but neuron fired long ago (Anti-Causal)
        if (pre_synaptic_spike_is_valid) begin
            if (input_weight > (post_synaptic_trace >> 2))
                intermediate_depressed_weight = input_weight - (post_synaptic_trace >> 2);
            else 
                intermediate_depressed_weight = 0;
        end else begin
            intermediate_depressed_weight = input_weight; // Keep original if no pre-spike
        end

        // --- LTP (Potentiation) Phase ---
        // Neuron firing NOW, Input was active recently (Causal)
        // Note: Independent evaluation allows true asynchronous STDP updates if architecture supports it
        if (post_synaptic_neuron_fire) begin
             if ((intermediate_depressed_weight + (pre_synaptic_trace >> 2)) < MAXIMUM_WEIGHT)
                output_weight = intermediate_depressed_weight + (pre_synaptic_trace >> 2);
             else 
                output_weight = MAXIMUM_WEIGHT;
        end else begin
             output_weight = intermediate_depressed_weight; // Keep depressed/original if no post-fire
        end
    end

endmodule
