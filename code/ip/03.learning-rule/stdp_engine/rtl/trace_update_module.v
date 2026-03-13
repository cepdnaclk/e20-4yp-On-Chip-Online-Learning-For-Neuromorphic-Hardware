// =============================================================================
// Module: trace_update_module
// Description: Self-contained processing unit for one trace operation.
//              Supports INCREASE (spike → trace up) and DECAY_COMPUTE
//              (lazy decay to get effective current value).
//              Uses barrel-shift-with-correction for decay.
//              2-cycle latency for both operation types.
// Spec Reference: Section 4.4
// =============================================================================

`timescale 1ns/1ps

module trace_update_module #(
    parameter TRACE_VALUE_BIT_WIDTH       = 8,
    parameter DECAY_TIMER_BIT_WIDTH       = 12,
    parameter TRACE_SATURATION_THRESHOLD  = 256,
    parameter DECAY_SHIFT_LOG2            = 3,
    parameter TRACE_INCREMENT_VALUE       = 32,
    parameter INCREASE_MODE               = 0    // passed to trace_increase_logic
)(
    input  wire                              clock,
    input  wire                              reset,

    // Control
    input  wire                              operation_start_pulse,
    input  wire                              operation_type_select,   // 0=INCREASE, 1=DECAY_COMPUTE

    // Inputs (valid when operation_start_pulse is high)
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]  input_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  input_trace_stored_timestamp,
    input  wire                              input_trace_saturated_flag,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  decay_timer_current_value,

    // Outputs
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]  result_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]  result_trace_stored_timestamp,
    output reg                               result_trace_saturated_flag,
    output reg                               result_valid_pulse,
    output wire                              module_busy_flag
);

    // -------------------------------------------------------------------------
    // State machine: IDLE → COMPUTE → DONE (back to IDLE)
    // Two-cycle pipeline: cycle 1 captures inputs, cycle 2 registers results.
    // -------------------------------------------------------------------------
    localparam STATE_IDLE    = 2'd0;
    localparam STATE_COMPUTE = 2'd1;

    reg [1:0] state_register;

    assign module_busy_flag = (state_register != STATE_IDLE);

    // Captured input registers
    reg [TRACE_VALUE_BIT_WIDTH-1:0]  captured_trace_value_register;
    reg [DECAY_TIMER_BIT_WIDTH-1:0]  captured_timestamp_register;
    reg                              captured_saturated_flag_register;
    reg [DECAY_TIMER_BIT_WIDTH-1:0]  captured_timer_value_register;
    reg                              captured_operation_type_register;

    // Trace increase logic (combinational, instantiated once)
    wire [TRACE_VALUE_BIT_WIDTH-1:0] increased_trace_value_wire;

    trace_increase_logic #(
        .TRACE_VALUE_BIT_WIDTH (TRACE_VALUE_BIT_WIDTH),
        .TRACE_INCREMENT_VALUE (TRACE_INCREMENT_VALUE),
        .INCREASE_MODE         (INCREASE_MODE)
    ) increase_logic_instance (
        .current_trace_value   (captured_trace_value_register),
        .increased_trace_value (increased_trace_value_wire)
    );

    // -------------------------------------------------------------------------
    // Decay computation (combinational wires derived from captured registers)
    // -------------------------------------------------------------------------
    wire [DECAY_TIMER_BIT_WIDTH-1:0] delta_t_value;
    assign delta_t_value = captured_timer_value_register - captured_timestamp_register;

    // shift_amount = delta_t >> DECAY_SHIFT_LOG2
    wire [DECAY_TIMER_BIT_WIDTH-1:0] shift_amount_value;
    assign shift_amount_value = delta_t_value >> DECAY_SHIFT_LOG2;

    // Barrel shift of trace value
    wire [TRACE_VALUE_BIT_WIDTH-1:0] shifted_trace_value;
    assign shifted_trace_value = captured_trace_value_register >> shift_amount_value;

    // Correction bit: bit at (shift_amount - 1) in original trace
    wire correction_bit;
    assign correction_bit = (shift_amount_value > 0) ?
                            ((captured_trace_value_register >> (shift_amount_value - 1)) & 1'b1) : 1'b0;

    // Corrected value with saturation
    wire [TRACE_VALUE_BIT_WIDTH:0] corrected_extended;
    assign corrected_extended = {1'b0, shifted_trace_value} + {{TRACE_VALUE_BIT_WIDTH{1'b0}}, correction_bit};

    wire [TRACE_VALUE_BIT_WIDTH-1:0] corrected_trace_value;
    assign corrected_trace_value = (corrected_extended > {1'b0, {TRACE_VALUE_BIT_WIDTH{1'b1}}}) ?
                                   {TRACE_VALUE_BIT_WIDTH{1'b1}} :
                                   corrected_extended[TRACE_VALUE_BIT_WIDTH-1:0];

    // Zero-output conditions
    wire saturation_flag_zero;
    wire delta_t_exceeds_threshold;
    wire shift_exceeds_width;

    assign saturation_flag_zero       = captured_saturated_flag_register;
    assign delta_t_exceeds_threshold  = (delta_t_value >= TRACE_SATURATION_THRESHOLD);
    assign shift_exceeds_width        = (shift_amount_value >= TRACE_VALUE_BIT_WIDTH);

    wire decay_goes_to_zero;
    assign decay_goes_to_zero = saturation_flag_zero || delta_t_exceeds_threshold || shift_exceeds_width;

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    always @(posedge clock) begin
        if (reset) begin
            state_register                  <= STATE_IDLE;
            result_valid_pulse              <= 1'b0;
            result_trace_value              <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            result_trace_stored_timestamp   <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            result_trace_saturated_flag     <= 1'b0;
            captured_trace_value_register   <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            captured_timestamp_register     <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            captured_saturated_flag_register <= 1'b0;
            captured_timer_value_register   <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            captured_operation_type_register <= 1'b0;
        end else begin
            result_valid_pulse <= 1'b0; // default: de-assert

            case (state_register)
                STATE_IDLE: begin
                    if (operation_start_pulse) begin
                        // Capture all inputs
                        captured_trace_value_register    <= input_trace_value;
                        captured_timestamp_register      <= input_trace_stored_timestamp;
                        captured_saturated_flag_register  <= input_trace_saturated_flag;
                        captured_timer_value_register     <= decay_timer_current_value;
                        captured_operation_type_register  <= operation_type_select;
                        state_register                   <= STATE_COMPUTE;
                    end
                end

                STATE_COMPUTE: begin
                    // Compute results based on operation type
                    if (captured_operation_type_register == 1'b0) begin
                        // INCREASE operation
                        result_trace_value            <= increased_trace_value_wire;
                        result_trace_stored_timestamp <= captured_timer_value_register;
                        result_trace_saturated_flag   <= 1'b0;
                    end else begin
                        // DECAY_COMPUTE operation
                        if (decay_goes_to_zero) begin
                            result_trace_value            <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
                            result_trace_saturated_flag   <= 1'b1;
                            result_trace_stored_timestamp <= captured_timestamp_register;
                        end else begin
                            result_trace_value            <= corrected_trace_value;
                            result_trace_saturated_flag   <= 1'b0;
                            result_trace_stored_timestamp <= captured_timestamp_register;
                        end
                    end

                    result_valid_pulse <= 1'b1;
                    state_register     <= STATE_IDLE;
                end

                default: begin
                    state_register <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
