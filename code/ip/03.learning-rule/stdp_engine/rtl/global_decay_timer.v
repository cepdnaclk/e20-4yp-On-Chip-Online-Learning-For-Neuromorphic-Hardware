// =============================================================================
// Module: global_decay_timer
// Description: Maintains the global decay tick counter used to timestamp trace
//              updates and compute lazy decay deltas. Increments only on
//              decay_enable_pulse, not every clock cycle.
// Spec Reference: Section 4.1
// =============================================================================

`timescale 1ns/1ps

module global_decay_timer #(
    parameter DECAY_TIMER_BIT_WIDTH = 12
)(
    input  wire                              clock,
    input  wire                              reset,
    input  wire                              decay_enable_pulse,
    output wire [DECAY_TIMER_BIT_WIDTH-1:0]  decay_timer_current_value
);

    reg [DECAY_TIMER_BIT_WIDTH-1:0] timer_register;

    assign decay_timer_current_value = timer_register;

    always @(posedge clock) begin
        if (reset) begin
            timer_register <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
        end else if (decay_enable_pulse) begin
            timer_register <= timer_register + 1'b1; // wraps naturally
        end
    end

endmodule
