// =============================================================================
// Module: trace_update_arbiter
// Description: Pool of trace_update_module instances. Routes each request to
//              the lowest-indexed idle module, tags the result with the
//              originating neuron address and operation type, and returns at
//              most one result per cycle.
//
// FIX: the old result path kept `fifo_entry_count_register` with a
// push/pop expression that double-counted on the "FIFO empty but pushing this
// cycle" path, so trace results were silently lost and the STDP controller
// waited forever for a completion count it would never reach. The FIFO is now
// a plain head/tail/count structure with an explicit bypass for the empty
// case, using blocking scratch variables so multi-push is exact.
// Spec Reference: Section 4.5
// =============================================================================

`timescale 1ns/1ps

module trace_update_arbiter #(
    parameter NUM_TRACE_UPDATE_MODULES    = 4,
    parameter NEURON_ADDRESS_WIDTH        = 6,
    parameter TRACE_VALUE_BIT_WIDTH       = 8,
    parameter DECAY_TIMER_BIT_WIDTH       = 12,
    parameter TRACE_SATURATION_THRESHOLD  = 256,
    parameter DECAY_SHIFT_LOG2            = 3,
    parameter TRACE_INCREMENT_VALUE       = 32,
    parameter INCREASE_MODE               = 0
)(
    input  wire                              clock,
    input  wire                              reset,

    input  wire                              request_valid,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]   request_neuron_address,
    input  wire                              request_operation_type,   // 0=INCREASE 1=DECAY
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]  request_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  request_trace_stored_timestamp,
    input  wire                              request_trace_saturated_flag,

    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  decay_timer_current_value,

    output wire                              all_modules_busy_flag,
    // High when no operation is in flight and no result is pending. The STDP
    // controller uses this to guarantee a transaction cannot be credited with
    // a trace result belonging to the previous one.
    output wire                              arbiter_idle_flag,

    output reg                               result_valid,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]   result_neuron_address,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]  result_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]  result_trace_stored_timestamp,
    output reg                               result_trace_saturated_flag,
    output reg                               result_operation_type
);

    wire [NUM_TRACE_UPDATE_MODULES-1:0] module_busy_flags;
    wire [NUM_TRACE_UPDATE_MODULES-1:0] module_result_valid_pulses;

    wire [TRACE_VALUE_BIT_WIDTH-1:0]  module_result_trace_values    [0:NUM_TRACE_UPDATE_MODULES-1];
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  module_result_timestamps      [0:NUM_TRACE_UPDATE_MODULES-1];
    wire                              module_result_saturated_flags [0:NUM_TRACE_UPDATE_MODULES-1];

    reg  [NUM_TRACE_UPDATE_MODULES-1:0] module_start_pulses;

    reg  [NEURON_ADDRESS_WIDTH-1:0] assigned_neuron_address_register [0:NUM_TRACE_UPDATE_MODULES-1];
    reg                             assigned_operation_type_register [0:NUM_TRACE_UPDATE_MODULES-1];

    assign all_modules_busy_flag = &module_busy_flags;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_TRACE_UPDATE_MODULES; gi = gi + 1) begin : gen_trace_modules
            trace_update_module #(
                .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
                .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
                .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
                .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
                .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
                .INCREASE_MODE              (INCREASE_MODE)
            ) trace_module_inst (
                .clock                        (clock),
                .reset                        (reset),
                .operation_start_pulse        (module_start_pulses[gi]),
                .operation_type_select        (request_operation_type),
                .input_trace_value            (request_trace_value),
                .input_trace_stored_timestamp (request_trace_stored_timestamp),
                .input_trace_saturated_flag   (request_trace_saturated_flag),
                .decay_timer_current_value    (decay_timer_current_value),
                .result_trace_value           (module_result_trace_values[gi]),
                .result_trace_stored_timestamp(module_result_timestamps[gi]),
                .result_trace_saturated_flag  (module_result_saturated_flags[gi]),
                .result_valid_pulse           (module_result_valid_pulses[gi]),
                .module_busy_flag             (module_busy_flags[gi])
            );
        end
    endgenerate

    // ---- Dispatch: lowest-indexed idle module ----
    reg [NUM_TRACE_UPDATE_MODULES-1:0] selected_module_one_hot;
    integer pe_idx;
    always @(*) begin
        selected_module_one_hot = {NUM_TRACE_UPDATE_MODULES{1'b0}};
        for (pe_idx = NUM_TRACE_UPDATE_MODULES - 1; pe_idx >= 0; pe_idx = pe_idx - 1) begin
            if (!module_busy_flags[pe_idx]) begin
                selected_module_one_hot = {NUM_TRACE_UPDATE_MODULES{1'b0}};
                selected_module_one_hot[pe_idx] = 1'b1;
            end
        end
    end

    always @(*) begin
        module_start_pulses = {NUM_TRACE_UPDATE_MODULES{1'b0}};
        if (request_valid && !all_modules_busy_flag)
            module_start_pulses = selected_module_one_hot;
    end

    integer tag_idx;
    always @(posedge clock) begin
        if (reset) begin
            for (tag_idx = 0; tag_idx < NUM_TRACE_UPDATE_MODULES; tag_idx = tag_idx + 1) begin
                assigned_neuron_address_register[tag_idx] <= {NEURON_ADDRESS_WIDTH{1'b0}};
                assigned_operation_type_register[tag_idx] <= 1'b0;
            end
        end else if (request_valid && !all_modules_busy_flag) begin
            for (tag_idx = 0; tag_idx < NUM_TRACE_UPDATE_MODULES; tag_idx = tag_idx + 1) begin
                if (selected_module_one_hot[tag_idx]) begin
                    assigned_neuron_address_register[tag_idx] <= request_neuron_address;
                    assigned_operation_type_register[tag_idx] <= request_operation_type;
                end
            end
        end
    end

    // ---- Result FIFO ----
    localparam ENTRY_WIDTH = NEURON_ADDRESS_WIDTH + TRACE_VALUE_BIT_WIDTH +
                             DECAY_TIMER_BIT_WIDTH + 1 + 1;
    localparam FIFO_DEPTH  = (NUM_TRACE_UPDATE_MODULES < 2) ? 2 : NUM_TRACE_UPDATE_MODULES;
    localparam FIFO_PTR_W  = $clog2(FIFO_DEPTH);
    localparam FIFO_CNT_W  = $clog2(FIFO_DEPTH + 1);

    reg [ENTRY_WIDTH-1:0] result_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0]  fifo_head_register;
    reg [FIFO_PTR_W-1:0]  fifo_tail_register;
    reg [FIFO_CNT_W-1:0]  fifo_count_register;

    integer               push_idx;
    reg [FIFO_PTR_W-1:0]  tail_scratch;
    reg [FIFO_CNT_W-1:0]  count_scratch;
    reg                   output_taken;

    assign arbiter_idle_flag = ~(|module_busy_flags) & ~(|module_result_valid_pulses) &
                               (fifo_count_register == 0) & ~result_valid;

    always @(posedge clock) begin
        if (reset) begin
            fifo_head_register            <= {FIFO_PTR_W{1'b0}};
            fifo_tail_register            <= {FIFO_PTR_W{1'b0}};
            fifo_count_register           <= {FIFO_CNT_W{1'b0}};
            result_valid                  <= 1'b0;
            result_neuron_address         <= {NEURON_ADDRESS_WIDTH{1'b0}};
            result_trace_value            <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            result_trace_stored_timestamp <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            result_trace_saturated_flag   <= 1'b0;
            result_operation_type         <= 1'b0;
        end else begin
            result_valid  <= 1'b0;
            tail_scratch  = fifo_tail_register;
            count_scratch = fifo_count_register;
            output_taken  = 1'b0;

            // Drain one queued entry first (oldest wins).
            if (count_scratch != 0) begin
                result_valid <= 1'b1;
                {result_neuron_address,
                 result_trace_value,
                 result_trace_stored_timestamp,
                 result_trace_saturated_flag,
                 result_operation_type} <= result_fifo[fifo_head_register];
                fifo_head_register <= (fifo_head_register + 1'b1) % FIFO_DEPTH;
                count_scratch = count_scratch - 1'b1;
                output_taken  = 1'b1;
            end

            // Completions this cycle: first one bypasses the FIFO if the
            // output port is still free, the rest queue up.
            for (push_idx = 0; push_idx < NUM_TRACE_UPDATE_MODULES; push_idx = push_idx + 1) begin
                if (module_result_valid_pulses[push_idx]) begin
                    if (!output_taken) begin
                        result_valid                  <= 1'b1;
                        result_neuron_address         <= assigned_neuron_address_register[push_idx];
                        result_trace_value            <= module_result_trace_values[push_idx];
                        result_trace_stored_timestamp <= module_result_timestamps[push_idx];
                        result_trace_saturated_flag   <= module_result_saturated_flags[push_idx];
                        result_operation_type         <= assigned_operation_type_register[push_idx];
                        output_taken                  = 1'b1;
                    end else if (count_scratch < FIFO_DEPTH) begin
                        result_fifo[tail_scratch] <=
                            {assigned_neuron_address_register[push_idx],
                             module_result_trace_values[push_idx],
                             module_result_timestamps[push_idx],
                             module_result_saturated_flags[push_idx],
                             assigned_operation_type_register[push_idx]};
                        tail_scratch  = (tail_scratch + 1'b1) % FIFO_DEPTH;
                        count_scratch = count_scratch + 1'b1;
                    end
                end
            end

            fifo_tail_register  <= tail_scratch;
            fifo_count_register <= count_scratch;
        end
    end

endmodule
