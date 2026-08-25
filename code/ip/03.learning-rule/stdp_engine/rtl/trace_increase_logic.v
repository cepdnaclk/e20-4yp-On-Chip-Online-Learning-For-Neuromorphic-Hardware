// =============================================================================
// Module: trace_increase_logic
// Description: Computes new trace value when a spike occurs.
//              Purely combinational and stateless.
// Spec Reference: Section 4.3
// =============================================================================
// ============================================================
// SWAPPABLE MODULE — Do NOT modify the port interface.
// Internal implementation may be replaced freely.
// See SNN Accelerator Requirements Specification Section 1.5.
// ============================================================

`timescale 1ns/1ps

module trace_increase_logic #(
    parameter TRACE_VALUE_BIT_WIDTH  = 8,
    parameter TRACE_INCREMENT_VALUE  = 32,
    parameter INCREASE_MODE          = 0   // 0 = SET_MAX, 1 = ADD_VALUE
)(
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0] current_trace_value,
    output wire [TRACE_VALUE_BIT_WIDTH-1:0] increased_trace_value
);

    localparam [TRACE_VALUE_BIT_WIDTH-1:0] MAX_TRACE_VALUE = {TRACE_VALUE_BIT_WIDTH{1'b1}};

    generate
        if (INCREASE_MODE == 0) begin : gen_set_max
            // SET_MAX: set all bits to 1
            assign increased_trace_value = MAX_TRACE_VALUE;
        end else begin : gen_add_value
            // ADD_VALUE: saturating add
            wire [TRACE_VALUE_BIT_WIDTH:0] sum_extended;
            assign sum_extended = {1'b0, current_trace_value} + TRACE_INCREMENT_VALUE[TRACE_VALUE_BIT_WIDTH:0];
            assign increased_trace_value = (sum_extended > MAX_TRACE_VALUE) ? MAX_TRACE_VALUE
                                                                            : sum_extended[TRACE_VALUE_BIT_WIDTH-1:0];
        end
    endgenerate

endmodule
