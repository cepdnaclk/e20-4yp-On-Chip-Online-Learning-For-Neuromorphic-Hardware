// =============================================================================
// Module: stdp_controller
// Description: Central FSM that orchestrates the complete STDP pipeline.
//              Coordinates connection matrix reads, trace operations via
//              the arbiter, weight bank reads/writes, weight distribution,
//              and weight update computation.
// Spec Reference: Section 4.12
// =============================================================================

`timescale 1ns/1ps

module stdp_controller #(
    parameter NUM_NEURONS_PER_CLUSTER  = 64,
    parameter NEURON_ADDRESS_WIDTH     = $clog2(NUM_NEURONS_PER_CLUSTER),
    parameter NUM_WEIGHT_BANKS         = 64,
    parameter WEIGHT_BANK_ADDRESS_WIDTH = NEURON_ADDRESS_WIDTH,
    parameter WEIGHT_BIT_WIDTH         = 8,
    parameter TRACE_VALUE_BIT_WIDTH    = 8,
    parameter DECAY_TIMER_BIT_WIDTH    = 12,
    parameter LTP_SHIFT_AMOUNT         = 2,
    parameter LTD_SHIFT_AMOUNT         = 2
)(
    input  wire                                                 clock,
    input  wire                                                 reset,

    // Spike queue interface
    input  wire [NEURON_ADDRESS_WIDTH-1:0]                      fired_neuron_address,
    input  wire                                                 fired_neuron_address_valid,
    output reg                                                  fired_neuron_address_acknowledge,

    // Global decay timer
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]                     decay_timer_current_value,

    // Trace memory interface
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      trace_memory_read_neuron_address,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]                     trace_memory_read_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]                     trace_memory_read_stored_timestamp,
    input  wire                                                 trace_memory_read_saturated_flag,
    output reg                                                  trace_memory_write_enable,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      trace_memory_write_neuron_address,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]                     trace_memory_write_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]                     trace_memory_write_stored_timestamp,
    output reg                                                  trace_memory_write_saturated_flag,

    // Trace update arbiter interface
    output reg                                                  arbiter_request_valid,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      arbiter_request_neuron_address,
    output reg                                                  arbiter_request_operation_type,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]                     arbiter_request_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]                     arbiter_request_trace_stored_timestamp,
    output reg                                                  arbiter_request_trace_saturated_flag,
    input  wire                                                 arbiter_all_modules_busy_flag,
    input  wire                                                 arbiter_result_valid,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]                      arbiter_result_neuron_address,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]                     arbiter_result_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]                     arbiter_result_stored_timestamp,
    input  wire                                                 arbiter_result_saturated_flag,
    input  wire                                                 arbiter_result_operation_type,

    // Connection matrix interface
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      connection_matrix_read_row_address,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]                   connection_matrix_row_input_vector,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]                   connection_matrix_row_output_vector,
    input  wire                                                 connection_matrix_row_data_valid,

    // Banked weight memory interface
    output reg                                                  weight_bank_row_read_enable,
    output reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                 weight_bank_row_read_address,
    input  wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]         weight_bank_row_weight_data_bus,
    input  wire                                                 weight_bank_row_data_valid,
    output reg                                                  weight_bank_column_read_enable,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      weight_bank_column_pre_neuron_address,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      weight_bank_column_step_counter,
    input  wire [WEIGHT_BIT_WIDTH-1:0]                          weight_bank_column_weight_output,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]                      weight_bank_column_target_neuron_index,
    input  wire                                                 weight_bank_column_data_valid,
    output reg  [NUM_WEIGHT_BANKS-1:0]                          weight_bank_write_enable_per_bank,
    output reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                 weight_bank_write_address,
    output reg  [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]         weight_bank_write_data_bus,

    // Weight distribution bus outputs
    output reg  [WEIGHT_BIT_WIDTH-1:0]                          weight_distribution_bus_data,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]                      weight_distribution_bus_target_neuron_address,
    output reg                                                  weight_distribution_bus_valid,

    // Status
    output reg                                                  stdp_controller_busy_flag
);

    // =========================================================================
    // State encoding
    // =========================================================================
    localparam STDP_CTRL_IDLE                               = 3'd0;
    localparam STDP_CTRL_READ_CONNECTION_MATRIX              = 3'd1;
    localparam STDP_CTRL_BEGIN_PARALLEL_PHASE                = 3'd2;
    localparam STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES = 3'd3;
    localparam STDP_CTRL_WAIT_FOR_TRACE_RESULTS              = 3'd4;
    localparam STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS           = 3'd5;

    reg [2:0] state_register;

    // =========================================================================
    // Internal registers (per spec §4.12)
    // =========================================================================
    reg [NEURON_ADDRESS_WIDTH-1:0]                  registered_fired_neuron_address_register;
    reg [NUM_NEURONS_PER_CLUSTER-1:0]               registered_input_connection_vector_register;
    reg [NUM_NEURONS_PER_CLUSTER-1:0]               registered_output_connection_vector_register;
    reg [NEURON_ADDRESS_WIDTH:0]                    column_step_counter_register; // +1 bit to reach NUM_NEURONS_PER_CLUSTER
    reg [NEURON_ADDRESS_WIDTH-1:0]                  pre_trace_request_pointer_register;
    localparam COUNT_WIDTH = NEURON_ADDRESS_WIDTH + 1; // enough to hold 0..NUM_NEURONS_PER_CLUSTER
    reg [COUNT_WIDTH-1:0]                           pending_trace_result_count_register;
    reg [COUNT_WIDTH-1:0]                           received_trace_result_count_register;
    reg [TRACE_VALUE_BIT_WIDTH-1:0]                 pre_synaptic_trace_result_store_register [0:NUM_NEURONS_PER_CLUSTER-1];
    reg [TRACE_VALUE_BIT_WIDTH-1:0]                 post_synaptic_trace_result_register;
    reg [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]     weight_bank_row_weight_data_bus_register;
    reg                                             row_read_data_captured_flag_register;

    // Activity completion flags for the parallel phase
    reg activity_a_complete_register;
    reg activity_b_complete_register;

    // Sub-state for connection matrix read: need a cycle for trace memory read
    // before we can issue the arbiter increase request
    reg                                             post_trace_read_pending_register;
    reg                                             post_increase_issued_register;

    // Pre-trace fetch sub-state
    reg                                             pre_trace_read_pending_register;
    reg [NEURON_ADDRESS_WIDTH-1:0]                  pre_trace_current_neuron_register;

    // Popcount of input connection vector (computed as a registered value)
    integer pc_idx;
    reg [COUNT_WIDTH-1:0] input_vector_popcount_register;

    // Find next set bit in input connection vector from current pointer
    integer nxt_idx;
    reg [NEURON_ADDRESS_WIDTH-1:0] next_set_bit_index;
    reg                            next_set_bit_found;
    always @(*) begin
        next_set_bit_index = {NEURON_ADDRESS_WIDTH{1'b0}};
        next_set_bit_found = 1'b0;
        for (nxt_idx = NUM_NEURONS_PER_CLUSTER - 1; nxt_idx >= 0; nxt_idx = nxt_idx - 1) begin
            if (nxt_idx >= pre_trace_request_pointer_register &&
                registered_input_connection_vector_register[nxt_idx]) begin
                next_set_bit_index = nxt_idx[NEURON_ADDRESS_WIDTH-1:0];
                next_set_bit_found = 1'b1;
            end
        end
    end

    // Weight update logic bank array (combinational, wired continuously)
    // Build pre-synaptic trace bus from stored results
    reg [NUM_WEIGHT_BANKS*TRACE_VALUE_BIT_WIDTH-1:0] pre_synaptic_trace_bus_for_update;
    integer trace_bus_idx;
    always @(*) begin
        for (trace_bus_idx = 0; trace_bus_idx < NUM_WEIGHT_BANKS; trace_bus_idx = trace_bus_idx + 1) begin
            pre_synaptic_trace_bus_for_update[trace_bus_idx*TRACE_VALUE_BIT_WIDTH +: TRACE_VALUE_BIT_WIDTH] =
                pre_synaptic_trace_result_store_register[
                    (trace_bus_idx - registered_fired_neuron_address_register + NUM_WEIGHT_BANKS) & (NUM_WEIGHT_BANKS - 1)
                ];
        end
    end

    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] updated_weight_bus_wire;

    weight_update_logic_bank_array #(
        .NUM_WEIGHT_BANKS      (NUM_WEIGHT_BANKS),
        .WEIGHT_BIT_WIDTH      (WEIGHT_BIT_WIDTH),
        .TRACE_VALUE_BIT_WIDTH (TRACE_VALUE_BIT_WIDTH),
        .LTP_SHIFT_AMOUNT      (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT      (LTD_SHIFT_AMOUNT)
    ) weight_update_array_inst (
        .all_banks_pre_synaptic_trace_bus (pre_synaptic_trace_bus_for_update),
        .post_synaptic_trace_value        (post_synaptic_trace_result_register),
        .all_banks_current_weight_bus     (weight_bank_row_weight_data_bus_register),
        .all_banks_updated_weight_bus     (updated_weight_bus_wire)
    );

    // =========================================================================
    // Main state machine
    // =========================================================================
    integer rst_idx;
    always @(posedge clock) begin
        if (reset) begin
            state_register                              <= STDP_CTRL_IDLE;
            connection_matrix_read_row_address          <= {NEURON_ADDRESS_WIDTH{1'b0}};
            trace_memory_read_neuron_address            <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_row_read_address                <= {WEIGHT_BANK_ADDRESS_WIDTH{1'b0}};
            weight_bank_column_pre_neuron_address       <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_column_step_counter             <= {NEURON_ADDRESS_WIDTH{1'b0}};
            stdp_controller_busy_flag                   <= 1'b0;
            input_vector_popcount_register = {COUNT_WIDTH{1'b0}};
            fired_neuron_address_acknowledge            <= 1'b0;
            trace_memory_write_enable                   <= 1'b0;
            arbiter_request_valid                       <= 1'b0;
            weight_bank_row_read_enable                 <= 1'b0;
            weight_bank_column_read_enable              <= 1'b0;
            weight_bank_write_enable_per_bank           <= {NUM_WEIGHT_BANKS{1'b0}};
            weight_distribution_bus_valid               <= 1'b0;
            registered_fired_neuron_address_register    <= {NEURON_ADDRESS_WIDTH{1'b0}};
            registered_input_connection_vector_register <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            registered_output_connection_vector_register<= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            column_step_counter_register                <= {NEURON_ADDRESS_WIDTH{1'b0}};
            pre_trace_request_pointer_register          <= {NEURON_ADDRESS_WIDTH{1'b0}};
            pending_trace_result_count_register         <= {COUNT_WIDTH{1'b0}};
            received_trace_result_count_register        <= {COUNT_WIDTH{1'b0}};
            post_synaptic_trace_result_register         <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            row_read_data_captured_flag_register        <= 1'b0;
            activity_a_complete_register                <= 1'b0;
            activity_b_complete_register                <= 1'b0;
            post_trace_read_pending_register            <= 1'b0;
            post_increase_issued_register               <= 1'b0;
            pre_trace_read_pending_register             <= 1'b0;
            pre_trace_current_neuron_register           <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_row_weight_data_bus_register    <= {(NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH){1'b0}};
            weight_bank_write_data_bus                  <= {(NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH){1'b0}};
            weight_bank_write_address                   <= {WEIGHT_BANK_ADDRESS_WIDTH{1'b0}};
            weight_distribution_bus_data                <= {WEIGHT_BIT_WIDTH{1'b0}};
            weight_distribution_bus_target_neuron_address <= {NEURON_ADDRESS_WIDTH{1'b0}};
            for (rst_idx = 0; rst_idx < NUM_NEURONS_PER_CLUSTER; rst_idx = rst_idx + 1) begin
                pre_synaptic_trace_result_store_register[rst_idx] <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            end
        end else begin
            // Default: de-assert single-cycle outputs
            fired_neuron_address_acknowledge  <= 1'b0;
            trace_memory_write_enable         <= 1'b0;
            arbiter_request_valid             <= 1'b0;
            weight_bank_row_read_enable       <= 1'b0;
            weight_bank_column_read_enable    <= 1'b0;
            weight_bank_write_enable_per_bank <= {NUM_WEIGHT_BANKS{1'b0}};
            weight_distribution_bus_valid     <= 1'b0;

            // ---- Always capture row read when valid (any state) ----
            if (weight_bank_row_data_valid && !row_read_data_captured_flag_register) begin
                weight_bank_row_weight_data_bus_register <= weight_bank_row_weight_data_bus;
                row_read_data_captured_flag_register     <= 1'b1;
            end

            // ---- Always handle arbiter results (any non-IDLE state) ----
            // The INCREASE request is issued in READ_CONNECTION_MATRIX, and
            // with 2-cycle trace module latency the result can arrive in
            // that same state or later. We must accept it immediately.
            if (arbiter_result_valid &&
                state_register != STDP_CTRL_IDLE) begin
                if (arbiter_result_operation_type == 1'b0) begin
                    // INCREASE result (post-synaptic trace)
                    post_synaptic_trace_result_register <= arbiter_result_trace_value;
                    // Write back to trace memory
                    trace_memory_write_enable           <= 1'b1;
                    trace_memory_write_neuron_address    <= arbiter_result_neuron_address;
                    trace_memory_write_trace_value       <= arbiter_result_trace_value;
                    trace_memory_write_stored_timestamp  <= arbiter_result_stored_timestamp;
                    trace_memory_write_saturated_flag    <= arbiter_result_saturated_flag;
                    received_trace_result_count_register <= received_trace_result_count_register + 1;
                end else begin
                    // DECAY_COMPUTE result (pre-synaptic trace)
                    pre_synaptic_trace_result_store_register[arbiter_result_neuron_address] <= arbiter_result_trace_value;
                    // Write back to trace memory
                    trace_memory_write_enable           <= 1'b1;
                    trace_memory_write_neuron_address    <= arbiter_result_neuron_address;
                    trace_memory_write_trace_value       <= arbiter_result_trace_value;
                    trace_memory_write_stored_timestamp  <= arbiter_result_stored_timestamp;
                    trace_memory_write_saturated_flag    <= arbiter_result_saturated_flag;
                    received_trace_result_count_register <= received_trace_result_count_register + 1;
                end
            end

            case (state_register)
                // =============================================================
                // IDLE
                // =============================================================
                STDP_CTRL_IDLE: begin
                    stdp_controller_busy_flag <= 1'b0;
                    if (fired_neuron_address_valid) begin
                        registered_fired_neuron_address_register <= fired_neuron_address;
                        fired_neuron_address_acknowledge         <= 1'b1;
                        stdp_controller_busy_flag                <= 1'b1;
                        state_register                           <= STDP_CTRL_READ_CONNECTION_MATRIX;
                        // Reset internal flags
                        row_read_data_captured_flag_register     <= 1'b0;
                        activity_a_complete_register             <= 1'b0;
                        activity_b_complete_register             <= 1'b0;
                        post_trace_read_pending_register         <= 1'b0;
                        post_increase_issued_register            <= 1'b0;
                        pre_trace_read_pending_register          <= 1'b0;
                        received_trace_result_count_register     <= {COUNT_WIDTH{1'b0}};
                        for (rst_idx = 0; rst_idx < NUM_NEURONS_PER_CLUSTER; rst_idx = rst_idx + 1) begin
                            pre_synaptic_trace_result_store_register[rst_idx] <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
                        end
                    end
                end

                // =============================================================
                // READ_CONNECTION_MATRIX
                // =============================================================
                STDP_CTRL_READ_CONNECTION_MATRIX: begin
                    // Present row address to connection matrix
                    connection_matrix_read_row_address <= registered_fired_neuron_address_register;

                    // Also read fired neuron's own trace (async read from trace memory)
                    if (!post_trace_read_pending_register && !post_increase_issued_register) begin
                        trace_memory_read_neuron_address  <= registered_fired_neuron_address_register;
                        post_trace_read_pending_register  <= 1'b1;
                    end

                    // On the next cycle, trace memory data is available (async),
                    // issue INCREASE to arbiter
                    if (post_trace_read_pending_register && !post_increase_issued_register) begin
                        if (!arbiter_all_modules_busy_flag) begin
                            arbiter_request_valid              <= 1'b1;
                            arbiter_request_neuron_address     <= registered_fired_neuron_address_register;
                            arbiter_request_operation_type     <= 1'b0; // INCREASE
                            arbiter_request_trace_value        <= trace_memory_read_trace_value;
                            arbiter_request_trace_stored_timestamp <= trace_memory_read_stored_timestamp;
                            arbiter_request_trace_saturated_flag   <= trace_memory_read_saturated_flag;
                            post_increase_issued_register      <= 1'b1;
                        end
                    end

                    // Wait for connection matrix data
                    if (connection_matrix_row_data_valid) begin
                        registered_input_connection_vector_register  <= connection_matrix_row_input_vector;
                        registered_output_connection_vector_register <= connection_matrix_row_output_vector;
                        column_step_counter_register                 <= {NEURON_ADDRESS_WIDTH{1'b0}};
                        pre_trace_request_pointer_register           <= {NEURON_ADDRESS_WIDTH{1'b0}};

                        // If post increase also issued, transition
                        if (post_increase_issued_register || (!arbiter_all_modules_busy_flag && post_trace_read_pending_register)) begin
                            // Compute pending count: popcount of input vector + 1 (post-synaptic INCREASE)
                            // We'll compute it in the next state since we just registered the vector
                            state_register <= STDP_CTRL_BEGIN_PARALLEL_PHASE;
                        end
                    end
                end

                // =============================================================
                // BEGIN_PARALLEL_PHASE
                // =============================================================
                STDP_CTRL_BEGIN_PARALLEL_PHASE: begin
                    // Compute popcount of input vector in registered logic
                    input_vector_popcount_register = {COUNT_WIDTH{1'b0}};
                    for (pc_idx = 0; pc_idx < NUM_NEURONS_PER_CLUSTER; pc_idx = pc_idx + 1) begin
                        input_vector_popcount_register = input_vector_popcount_register + {{(COUNT_WIDTH-1){1'b0}}, registered_input_connection_vector_register[pc_idx]};
                    end
                    // Set pending count = popcount(input_vector) + 1 (for post-synaptic INCREASE)
                    pending_trace_result_count_register <= input_vector_popcount_register + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};

                    // Issue row read to weight memory
                    weight_bank_row_read_enable  <= 1'b1;
                    weight_bank_row_read_address <= registered_fired_neuron_address_register;

                    // Begin column read (step 0)
                    weight_bank_column_read_enable         <= 1'b1;
                    weight_bank_column_pre_neuron_address   <= registered_fired_neuron_address_register;
                    weight_bank_column_step_counter         <= {NEURON_ADDRESS_WIDTH{1'b0}};
                    column_step_counter_register            <= {{(NEURON_ADDRESS_WIDTH-1){1'b0}}, 1'b1}; // next step = 1

                    state_register <= STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES;
                end

                // =============================================================
                // DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES
                // =============================================================
                STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES: begin
                    // ---- Activity A: Weight Distribution ----
                    if (weight_bank_column_data_valid) begin
                        // Check if fired neuron connects to this post-synaptic neuron
                        if (registered_output_connection_vector_register[weight_bank_column_target_neuron_index]) begin
                            weight_distribution_bus_valid                <= 1'b1;
                            weight_distribution_bus_data                 <= weight_bank_column_weight_output;
                            weight_distribution_bus_target_neuron_address <= weight_bank_column_target_neuron_index;
                        end
                    end

                    // Issue next column read if not done
                    if (column_step_counter_register < NUM_NEURONS_PER_CLUSTER) begin
                        weight_bank_column_read_enable       <= 1'b1;
                        weight_bank_column_pre_neuron_address <= registered_fired_neuron_address_register;
                        weight_bank_column_step_counter       <= column_step_counter_register;
                        column_step_counter_register          <= column_step_counter_register + 1;
                    end else begin
                        activity_a_complete_register <= 1'b1;
                    end

                    // ---- Activity B: Pre-Synaptic Trace Fetches ----
                    if (!activity_b_complete_register) begin
                        if (!pre_trace_read_pending_register) begin
                            // Find next neuron with input connection
                            if (next_set_bit_found) begin
                                trace_memory_read_neuron_address <= next_set_bit_index;
                                pre_trace_read_pending_register  <= 1'b1;
                                pre_trace_current_neuron_register <= next_set_bit_index;
                            end else begin
                                activity_b_complete_register <= 1'b1;
                            end
                        end else begin
                            // Issue DECAY_COMPUTE request to arbiter
                            if (!arbiter_all_modules_busy_flag) begin
                                arbiter_request_valid              <= 1'b1;
                                arbiter_request_neuron_address     <= pre_trace_current_neuron_register;
                                arbiter_request_operation_type     <= 1'b1; // DECAY_COMPUTE
                                arbiter_request_trace_value        <= trace_memory_read_trace_value;
                                arbiter_request_trace_stored_timestamp <= trace_memory_read_stored_timestamp;
                                arbiter_request_trace_saturated_flag   <= trace_memory_read_saturated_flag;
                                pre_trace_read_pending_register    <= 1'b0;
                                pre_trace_request_pointer_register <= pre_trace_current_neuron_register + 1;
                            end
                            // else: hold, retry next cycle
                        end
                    end

                    // ---- Transition condition ----
                    if (activity_a_complete_register && activity_b_complete_register) begin
                        state_register <= STDP_CTRL_WAIT_FOR_TRACE_RESULTS;
                    end
                    // Also check if both become complete this cycle
                    if ((column_step_counter_register >= NUM_NEURONS_PER_CLUSTER) &&
                        (!next_set_bit_found && !pre_trace_read_pending_register)) begin
                        state_register <= STDP_CTRL_WAIT_FOR_TRACE_RESULTS;
                    end
                end

                // =============================================================
                // WAIT_FOR_TRACE_RESULTS
                // =============================================================
                STDP_CTRL_WAIT_FOR_TRACE_RESULTS: begin
                    // Continue issuing pending trace requests if any remain
                    if (!activity_b_complete_register) begin
                        if (!pre_trace_read_pending_register) begin
                            if (next_set_bit_found) begin
                                trace_memory_read_neuron_address <= next_set_bit_index;
                                pre_trace_read_pending_register  <= 1'b1;
                                pre_trace_current_neuron_register <= next_set_bit_index;
                            end else begin
                                activity_b_complete_register <= 1'b1;
                            end
                        end else begin
                            if (!arbiter_all_modules_busy_flag) begin
                                arbiter_request_valid              <= 1'b1;
                                arbiter_request_neuron_address     <= pre_trace_current_neuron_register;
                                arbiter_request_operation_type     <= 1'b1;
                                arbiter_request_trace_value        <= trace_memory_read_trace_value;
                                arbiter_request_trace_stored_timestamp <= trace_memory_read_stored_timestamp;
                                arbiter_request_trace_saturated_flag   <= trace_memory_read_saturated_flag;
                                pre_trace_read_pending_register    <= 1'b0;
                                pre_trace_request_pointer_register <= pre_trace_current_neuron_register + 1;
                            end
                        end
                    end

                    // Transition when all results received AND row read data captured
                    if (received_trace_result_count_register >= pending_trace_result_count_register &&
                        row_read_data_captured_flag_register) begin
                        state_register <= STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS;
                    end
                end

                // =============================================================
                // COMPUTE_AND_WRITE_WEIGHTS
                // =============================================================
                STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS: begin
                    // weight_update_logic_bank_array outputs are valid combinationally
                    // via updated_weight_bus_wire.
                    // Safety check: don't write if column read is in progress
                    if (!weight_bank_column_data_valid) begin
                        weight_bank_write_enable_per_bank <= {NUM_WEIGHT_BANKS{1'b1}};
                        weight_bank_write_address         <= registered_fired_neuron_address_register;
                        weight_bank_write_data_bus        <= updated_weight_bus_wire;
                        state_register                    <= STDP_CTRL_IDLE;
                    end
                    // else: delay write by one cycle (conflict guard)
                end

                default: begin
                    state_register <= STDP_CTRL_IDLE;
                end
            endcase
        end
    end

endmodule
