// STDP logic implementation
// Code by: Ravindu Pathirage (University of Peradeniya)
 
module stdp_neuron_core #(
    parameter DATA_WIDTH = 16,      // Width of weights and traces
    parameter ADDR_WIDTH = 10,      // Number of synapses (2^10 = 1024)
    parameter DECAY_SHIFT = 1,      // Decay factor (Higher = Slower decay)
    parameter LTP_WINDOW = 8'd20,   // Max value added for Potentiation
    parameter LTD_WINDOW = 8'd20,   // Max value subtracted for Depression
    parameter MAX_WEIGHT = 16'h7FFF // Max positive weight
)(
    input  wire                  clk,
    input  wire                  reset_n,
    
    // Neural Events
    input  wire                  post_fire,      // The neuron itself spiked (LTP trigger)
    input  wire                  pre_spike_in,   // A specific input synapse spiked (LTD trigger)
    input  wire [ADDR_WIDTH-1:0] syn_addr,       // Address of the synapse being processed
    
    // Weight Memory Interface (Read/Write)
    input  wire [DATA_WIDTH-1:0] weight_in,      // Current weight from RAM
    output reg  [DATA_WIDTH-1:0] weight_out,     // Updated weight to RAM
    output reg                   weight_write_enable,      // Write Enable
    
    // Trace Memory Interface (Need to store the Pre-trace for every synapse)
    input  wire [DATA_WIDTH-1:0] pre_trace_in,   // Trace value for this synapse
    output reg  [DATA_WIDTH-1:0] pre_trace_out,  // Updated trace value
    output reg                   trace_write_enable        // Trace Write Enable
);

    // -- Internal Registers --
    reg [DATA_WIDTH-1:0] post_trace; // Single register for the Neuron's own trace
    // Precompute shifted values to avoid duplicate shifts
    reg [DATA_WIDTH-1:0] post_trace_shifted;
    reg [DATA_WIDTH-1:0] pre_trace_in_shifted;

    // -- 1. Post-Synaptic Trace Logic (Global to Neuron) --
    // This trace decays every cycle (or timestep) and spikes when neuron fires
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            post_trace <= 0;
        end else begin
            if (post_fire) begin
                post_trace <= {1'b0, {(DATA_WIDTH-1){1'b1}}}; // Max value on spike
            end else begin
                // Simple geometric decay: x = x - (x >> shift)
                post_trace <= post_trace - (post_trace >> DECAY_SHIFT);
                // TODO: post_trace may never be 0 due to the nature of the decay. Consider adding a threshold below which it is set to 0.
            end
        end
    end

    // -- 2. STDP Update Logic --
    // We calculate the new weight and trace combinatorially, then latch them.
    
    always @(*) begin
      // Defaults
      weight_out              = weight_in;
      weight_write_enable     = 1'b0;
      pre_trace_out           = pre_trace_in;
      trace_write_enable      = 1'b0;

      post_trace_shifted = post_trace >> 2; // Pre-calculating
      pre_trace_in_shifted = pre_trace_in >> 2; // Pre-calculating

      // ---------------------------------------------------------
      // CASE A: Pre-Synaptic Spike Arrives (LTD(Long-Term Depression) Event)
      // The Pre-neuron fired. If the Post-neuron fired recently 
      // (high post_trace), it means Post came BEFORE Pre.
      // This is anti-causal => We Weaken (Depress) the synapse.
      // ---------------------------------------------------------
      if (pre_spike_in) begin
        // 1. Update Pre-Trace (It just spiked)
        pre_trace_out = {1'b0, {(DATA_WIDTH-1){1'b1}}}; // Reset to Max
        trace_write_enable      = 1'b1;

        // 2. Apply LTD to Weight
        // Weight = Weight - (LearningRate * PostTrace)
        // Simplified: Weight = Weight - (PostTrace >> Scale)
        if (weight_in > post_trace_shifted) 
            weight_out = weight_in - post_trace_shifted; // Tuning divisor
        else 
            weight_out = 0; // Saturate at 0
        
        weight_write_enable = 1'b1;
      end
      
      // ---------------------------------------------------------
      // CASE B: Post-Synaptic Spike Occurs (LTP(Long-Term Potentiation) Event)
      // The Neuron fired. We must check all synapses (sequentially 
      // via syn_addr) to see if they were active recently.
      // If Pre-trace is high, Pre came BEFORE Post.
      // This is causal => We Strengthen (Potentiate) the synapse.
      // ---------------------------------------------------------
      else if (post_fire) begin
        // 1. Decay the Pre-Trace (Passive decay step)
        // Note: In real hardware, you might decay traces only when accessing them
        pre_trace_out = pre_trace_in - (pre_trace_in >> DECAY_SHIFT);
        // TODO: pre_trace_out/in may never be 0 due to the nature of the decay. Consider adding a threshold below which it is set to 0.
        trace_write_enable      = 1'b1;

        // 2. Apply LTP to Weight
        // Weight = Weight + (PreTrace >> Scale)
        // TODO: optimize by pre-shifting the trace values to avoid duplicate
        // shifts in both cases
        if ((weight_in + pre_trace_in_shifted) < MAX_WEIGHT)
            weight_out = weight_in + pre_trace_in_shifted;
        else 
            weight_out = MAX_WEIGHT; // Saturate at Max
        
        weight_write_enable = 1'b1;
      end
    end
endmodule
