// =============================================================================
// Module: trace_update_arbiter
// Description: Manages a pool of trace_update_module instances. Routes
//              requests to the first available module, tags results with
//              originating neuron address, and uses an output FIFO for
//              multi-completion handling.
// Spec Reference: Section 4.5
// =============================================================================

`timescale 1ns/1ps

module trace_update_arbiter #(
    parameter NUM_TRACE_UPDATE_MODULES    = 64,
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

    // Request interface (from STDP controller)
    input  wire                              request_valid,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]   request_neuron_address,
    input  wire                              request_operation_type,     // 0=INCREASE, 1=DECAY_COMPUTE
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]  request_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  request_trace_stored_timestamp,
    input  wire                              request_trace_saturated_flag,

    // Global timer
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]  decay_timer_current_value,

    // Status
    output wire                              all_modules_busy_flag,

    // Result interface (to STDP controller)
    output reg                               result_valid,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]   result_neuron_address,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]  result_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]  result_trace_stored_timestamp,
    output reg                               result_trace_saturated_flag,
    output reg                               result_operation_type
);

    // -------------------------------------------------------------------------
    // Per-module wires
    // -------------------------------------------------------------------------
    wire [NUM_TRACE_UPDATE_MODULES-1:0] module_busy_flags;
    wire [NUM_TRACE_UPDATE_MODULES-1:0] module_result_valid_pulses;

    wire [TRACE_VALUE_BIT_WIDTH-1:0]    module_result_trace_values      [0:NUM_TRACE_UPDATE_MODULES-1];
    wire [DECAY_TIMER_BIT_WIDTH-1:0]    module_result_timestamps        [0:NUM_TRACE_UPDATE_MODULES-1];
    wire                                module_result_saturated_flags   [0:NUM_TRACE_UPDATE_MODULES-1];

    reg  [NUM_TRACE_UPDATE_MODULES-1:0] module_start_pulses;

    // Tag registers per module
    reg  [NEURON_ADDRESS_WIDTH-1:0]     assigned_neuron_address_register [0:NUM_TRACE_UPDATE_MODULES-1];
    reg                                 assigned_operation_type_register [0:NUM_TRACE_UPDATE_MODULES-1];

    // -------------------------------------------------------------------------
    // All-busy flag
    // -------------------------------------------------------------------------
    assign all_modules_busy_flag = &module_busy_flags;

    // -------------------------------------------------------------------------
    // Generate trace update module instances
    // -------------------------------------------------------------------------
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
                .clock                       (clock),
                .reset                       (reset),
                .operation_start_pulse       (module_start_pulses[gi]),
                .operation_type_select       (request_operation_type),
                .input_trace_value           (request_trace_value),
                .input_trace_stored_timestamp(request_trace_stored_timestamp),
                .input_trace_saturated_flag  (request_trace_saturated_flag),
                .decay_timer_current_value   (decay_timer_current_value),
                .result_trace_value          (module_result_trace_values[gi]),
                .result_trace_stored_timestamp(module_result_timestamps[gi]),
                .result_trace_saturated_flag (module_result_saturated_flags[gi]),
                .result_valid_pulse          (module_result_valid_pulses[gi]),
                .module_busy_flag            (module_busy_flags[gi])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Priority encoder: find first non-busy module
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Dispatch logic: generate start pulses and store tags
    // -------------------------------------------------------------------------
    integer disp_idx;
    always @(*) begin
        module_start_pulses = {NUM_TRACE_UPDATE_MODULES{1'b0}};
        if (request_valid && !all_modules_busy_flag) begin
            module_start_pulses = selected_module_one_hot;
        end
    end

    integer tag_idx;
    always @(posedge clock) begin
        if (reset) begin
            for (tag_idx = 0; tag_idx < NUM_TRACE_UPDATE_MODULES; tag_idx = tag_idx + 1) begin
                assigned_neuron_address_register[tag_idx] <= {NEURON_ADDRESS_WIDTH{1'b0}};
                assigned_operation_type_register[tag_idx] <= 1'b0;
            end
        end else begin
            if (request_valid && !all_modules_busy_flag) begin
                for (tag_idx = 0; tag_idx < NUM_TRACE_UPDATE_MODULES; tag_idx = tag_idx + 1) begin
                    if (selected_module_one_hot[tag_idx]) begin
                        assigned_neuron_address_register[tag_idx] <= request_neuron_address;
                        assigned_operation_type_register[tag_idx] <= request_operation_type;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output FIFO for results (depth = NUM_TRACE_UPDATE_MODULES)
    // Handles rare case where multiple modules complete on the same cycle.
    // -------------------------------------------------------------------------
    localparam RESULT_ENTRY_WIDTH = NEURON_ADDRESS_WIDTH + TRACE_VALUE_BIT_WIDTH +
                                   DECAY_TIMER_BIT_WIDTH + 1 + 1; // addr + value + ts + sat + op_type
    localparam FIFO_DEPTH = NUM_TRACE_UPDATE_MODULES;
    localparam FIFO_ADDR_WIDTH = $clog2(FIFO_DEPTH + 1);

    reg [RESULT_ENTRY_WIDTH-1:0] result_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_ADDR_WIDTH-1:0]    fifo_head_pointer_register;
    reg [FIFO_ADDR_WIDTH-1:0]    fifo_tail_pointer_register;
    reg [FIFO_ADDR_WIDTH-1:0]    fifo_entry_count_register;

    wire fifo_empty = (fifo_entry_count_register == 0);
    wire fifo_full  = (fifo_entry_count_register == FIFO_DEPTH);

    // Count how many modules have results this cycle
    // and push them all into the FIFO
    integer push_idx;
    integer pop_count;
    reg [FIFO_ADDR_WIDTH-1:0] push_count_this_cycle;

    always @(posedge clock) begin
        if (reset) begin
            fifo_head_pointer_register <= 0;
            fifo_tail_pointer_register <= 0;
            fifo_entry_count_register  <= 0;
            result_valid               <= 1'b0;
            result_neuron_address      <= {NEURON_ADDRESS_WIDTH{1'b0}};
            result_trace_value         <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            result_trace_stored_timestamp <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            result_trace_saturated_flag <= 1'b0;
            result_operation_type       <= 1'b0;
        end else begin
            // ---- Push results from completed modules ----
            push_count_this_cycle = 0;
            for (push_idx = 0; push_idx < NUM_TRACE_UPDATE_MODULES; push_idx = push_idx + 1) begin
                if (module_result_valid_pulses[push_idx] && !fifo_full) begin
                    result_fifo[(fifo_tail_pointer_register + push_count_this_cycle) % FIFO_DEPTH] <=
                        {assigned_neuron_address_register[push_idx],
                         module_result_trace_values[push_idx],
                         module_result_timestamps[push_idx],
                         module_result_saturated_flags[push_idx],
                         assigned_operation_type_register[push_idx]};
                    push_count_this_cycle = push_count_this_cycle + 1;
                end
            end
            fifo_tail_pointer_register <= (fifo_tail_pointer_register + push_count_this_cycle) % FIFO_DEPTH;

            // ---- Pop head entry if FIFO non-empty ----
            if (!fifo_empty || push_count_this_cycle > 0) begin
                // If FIFO was empty but we just pushed, the new data is at the old tail
                if (fifo_empty && push_count_this_cycle > 0) begin
                    // Pop from what was just pushed (current head = old tail = fifo_head_pointer_register)
                    result_valid <= 1'b1;
                    {result_neuron_address,
                     result_trace_value,
                     result_trace_stored_timestamp,
                     result_trace_saturated_flag,
                     result_operation_type} <= {assigned_neuron_address_register[0],
                                                 module_result_trace_values[0],
                                                 module_result_timestamps[0],
                                                 module_result_saturated_flags[0],
                                                 assigned_operation_type_register[0]};
                    // Find the first completed module for direct output
                    for (push_idx = 0; push_idx < NUM_TRACE_UPDATE_MODULES; push_idx = push_idx + 1) begin
                        if (module_result_valid_pulses[push_idx]) begin
                            result_neuron_address <= assigned_neuron_address_register[push_idx];
                            result_trace_value    <= module_result_trace_values[push_idx];
                            result_trace_stored_timestamp <= module_result_timestamps[push_idx];
                            result_trace_saturated_flag   <= module_result_saturated_flags[push_idx];
                            result_operation_type <= assigned_operation_type_register[push_idx];
                        end
                    end
                    // We consumed one from the push count
                    fifo_head_pointer_register <= (fifo_head_pointer_register + 1) % FIFO_DEPTH;
                    fifo_entry_count_register  <= fifo_entry_count_register + push_count_this_cycle - 1;
                end else if (!fifo_empty) begin
                    result_valid <= 1'b1;
                    {result_neuron_address,
                     result_trace_value,
                     result_trace_stored_timestamp,
                     result_trace_saturated_flag,
                     result_operation_type} <= result_fifo[fifo_head_pointer_register];
                    fifo_head_pointer_register <= (fifo_head_pointer_register + 1) % FIFO_DEPTH;
                    fifo_entry_count_register  <= fifo_entry_count_register + push_count_this_cycle - 1;
                end else begin
                    result_valid <= 1'b0;
                    fifo_entry_count_register <= fifo_entry_count_register + push_count_this_cycle;
                end
            end else begin
                result_valid <= 1'b0;
                fifo_entry_count_register <= fifo_entry_count_register + push_count_this_cycle;
            end
        end
    end

endmodule
