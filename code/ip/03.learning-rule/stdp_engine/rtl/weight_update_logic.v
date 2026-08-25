// =============================================================================
// Module: weight_update_logic
// Description: Computes new weight for a single synapse during STDP.
//              Purely combinational: LTP when pre-trace > 0, LTD otherwise.
// Spec Reference: Section 4.7
// =============================================================================
// ============================================================
// SWAPPABLE MODULE — Do NOT modify the port interface.
// Internal implementation may be replaced freely.
// See SNN Accelerator Requirements Specification Section 1.5.
// ============================================================

`timescale 1ns/1ps

module weight_update_logic #(
    parameter WEIGHT_BIT_WIDTH       = 8,
    parameter TRACE_VALUE_BIT_WIDTH  = 8,
    parameter LTP_SHIFT_AMOUNT       = 2,
    parameter LTD_SHIFT_AMOUNT       = 2
)(
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0] pre_synaptic_trace_value,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0] post_synaptic_trace_value,
    input  wire [WEIGHT_BIT_WIDTH-1:0]      current_weight_value,
    output reg  [WEIGHT_BIT_WIDTH-1:0]      updated_weight_value
);

    localparam [WEIGHT_BIT_WIDTH-1:0] MAX_WEIGHT = {WEIGHT_BIT_WIDTH{1'b1}};

    reg [WEIGHT_BIT_WIDTH:0] temp_weight; // one extra bit for overflow detection

    always @(*) begin
        if (pre_synaptic_trace_value > 0) begin
            // LTP: pre-synaptic neuron fired before post-synaptic (causal)
            temp_weight = {1'b0, current_weight_value} + (pre_synaptic_trace_value >> LTP_SHIFT_AMOUNT);
            if (temp_weight > MAX_WEIGHT)
                updated_weight_value = MAX_WEIGHT;
            else
                updated_weight_value = temp_weight[WEIGHT_BIT_WIDTH-1:0];
        end else begin
            // LTD: pre-synaptic had no recent activity (anti-causal)
            if (current_weight_value >= (post_synaptic_trace_value >> LTD_SHIFT_AMOUNT))
                updated_weight_value = current_weight_value - (post_synaptic_trace_value >> LTD_SHIFT_AMOUNT);
            else
                updated_weight_value = {WEIGHT_BIT_WIDTH{1'b0}};
        end
    end

endmodule
