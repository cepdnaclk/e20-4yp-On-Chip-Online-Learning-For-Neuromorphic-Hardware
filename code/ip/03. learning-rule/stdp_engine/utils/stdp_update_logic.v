// Filename: stdp_update_logic.v
// Description: Pure Combinational Logic for STDP.

module stdp_update_logic #(
    parameter WEIGHT_WIDTH = 16,
    parameter MAX_WEIGHT   = 16'h7FFF
)(
    input  wire [WEIGHT_WIDTH-1:0] weight_in,
    input  wire [WEIGHT_WIDTH-1:0] pre_trace,      // Shared Row Trace
    input  wire [WEIGHT_WIDTH-1:0] post_trace,     // Local Column Trace
    input  wire                    pre_spike_valid, // Event: Input Spiked
    input  wire                    post_fire,       // Event: Neuron Fired
    
    output reg  [WEIGHT_WIDTH-1:0] weight_out
);

    always @(*) begin
        // Default: Keep weight same
        weight_out = weight_in;

        // --- LTD (Depression) ---
        // Input spiked, but neuron fired long ago (Anti-Causal)
        if (pre_spike_valid) begin
            if (weight_in > (post_trace >> 2)) 
                weight_out = weight_in - (post_trace >> 2);
            else 
                weight_out = 0;
        end

        // --- LTP (Potentiation) ---
        // Neuron firing NOW, Input was active recently (Causal)
        // Note: We use the output of the LTD block as input here to handle
        // simultaneous events (rare but possible).
        if (pre_spike_valid && post_fire) begin
             if ((weight_out + (pre_trace >> 2)) < MAX_WEIGHT)
                weight_out = weight_out + (pre_trace >> 2);
             else 
                weight_out = MAX_WEIGHT;
        end
        // If only post_fire happens (without pre_spike valid for this row),
        // we technically don't update this specific synapse in this architecture
        // because we only fetch rows on input events. 
    end

endmodule
