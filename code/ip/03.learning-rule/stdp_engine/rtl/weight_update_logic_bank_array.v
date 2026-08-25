// =============================================================================
// Module: weight_update_logic_bank_array
// Description: Instantiates NUM_WEIGHT_BANKS copies of weight_update_logic
//              operating in parallel. Purely combinational.
// Spec Reference: Section 4.8
// =============================================================================

`timescale 1ns/1ps

module weight_update_logic_bank_array #(
    parameter NUM_WEIGHT_BANKS      = 64,
    parameter WEIGHT_BIT_WIDTH      = 8,
    parameter TRACE_VALUE_BIT_WIDTH = 8,
    parameter LTP_SHIFT_AMOUNT      = 2,
    parameter LTD_SHIFT_AMOUNT      = 2
)(
    input  wire [NUM_WEIGHT_BANKS*TRACE_VALUE_BIT_WIDTH-1:0]  all_banks_pre_synaptic_trace_bus,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]                   post_synaptic_trace_value,
    input  wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]       all_banks_current_weight_bus,
    output wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]       all_banks_updated_weight_bus
);

    genvar bi;
    generate
        for (bi = 0; bi < NUM_WEIGHT_BANKS; bi = bi + 1) begin : gen_weight_update
            weight_update_logic #(
                .WEIGHT_BIT_WIDTH      (WEIGHT_BIT_WIDTH),
                .TRACE_VALUE_BIT_WIDTH (TRACE_VALUE_BIT_WIDTH),
                .LTP_SHIFT_AMOUNT      (LTP_SHIFT_AMOUNT),
                .LTD_SHIFT_AMOUNT      (LTD_SHIFT_AMOUNT)
            ) weight_logic_inst (
                .pre_synaptic_trace_value  (all_banks_pre_synaptic_trace_bus[bi*TRACE_VALUE_BIT_WIDTH +: TRACE_VALUE_BIT_WIDTH]),
                .post_synaptic_trace_value (post_synaptic_trace_value),
                .current_weight_value      (all_banks_current_weight_bus[bi*WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH]),
                .updated_weight_value      (all_banks_updated_weight_bus[bi*WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH])
            );
        end
    endgenerate

endmodule
