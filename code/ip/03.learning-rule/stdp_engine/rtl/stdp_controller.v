// =============================================================================
// Module: stdp_controller
// Description: Central FSM. One "transaction" per spiking neuron.
//
// Transaction for a spiking neuron f:
//   1. Look up f's connectivity row (combinational read now).
//        input_vector [j] = 1  ->  j is PRE-synaptic to f
//        output_vector[j] = 1  ->  f drives j
//   2. INCREASE f's own trace (records "f fired at time T").
//   3. In parallel:
//        A) for every j in output_vector: column-read W(f -> j) and push it on
//           the weight distribution bus so neuron j integrates it.  (INFERENCE)
//        B) for every j in input_vector: read trace[j] and run DECAY_COMPUTE to
//           get its effective value now.                            (LEARNING)
//      and issue a row read of all incoming weights W(* -> f).
//   4. Wait until every trace result has come back.
//   5. Compute all updated weights in parallel and write them back:
//        pre_trace > 0  -> LTP  w += pre_trace >> LTP_SHIFT_AMOUNT
//        pre_trace == 0 -> LTD  w -= post_trace >> LTD_SHIFT_AMOUNT
//
// FIXES vs the previous version:
//   * P0 stale connectivity: the row address is now registered in IDLE, one
//     full cycle before SETUP consumes it, and cluster_connection_matrix reads
//     combinationally. Previously the address was assigned in the same state
//     that latched the result, and row_data_valid was hard-wired high, so
//     every transaction used the PREVIOUS neuron's connectivity.
//   * P1 O(N) scan: activities A and B now walk only the SET BITS of the
//     connection vectors, one per cycle, instead of stepping all N columns and
//     spending 2 cycles per pre-synaptic trace. For the MNIST layout this cuts
//     a transaction from ~600 cycles to ~50 (input spike) / ~200 (output spike).
//   * P1 pointer wrap: the scan pointers are COUNT_WIDTH bits so a set bit at
//     index N-1 advances the pointer to N and terminates instead of wrapping
//     to 0 and re-scanning forever.
//   * P2 write mask: only banks holding an actually-connected pre-synaptic
//     weight are written, instead of all N banks unconditionally.
//   * New: learning_enable gates weight writes (inference-only phases), and a
//     transaction watchdog turns a would-be hang into a visible flag.
// Spec Reference: Section 4.12
// =============================================================================

`timescale 1ns/1ps

module stdp_controller #(
    parameter NUM_NEURONS_PER_CLUSTER   = 64,
    parameter NEURON_ADDRESS_WIDTH      = $clog2(NUM_NEURONS_PER_CLUSTER),
    parameter NUM_WEIGHT_BANKS          = 64,
    parameter WEIGHT_BANK_ADDRESS_WIDTH = NEURON_ADDRESS_WIDTH,
    parameter WEIGHT_BIT_WIDTH          = 8,
    parameter TRACE_VALUE_BIT_WIDTH     = 8,
    parameter DECAY_TIMER_BIT_WIDTH     = 12,
    parameter LTP_SHIFT_AMOUNT          = 3,
    parameter LTD_SHIFT_AMOUNT          = 6,
    parameter TRANSACTION_TIMEOUT       = 4096
)(
    input  wire                                          clock,
    input  wire                                          reset,
    input  wire                                          learning_enable,

    // Spike queue interface
    input  wire [NEURON_ADDRESS_WIDTH-1:0]               fired_neuron_address,
    input  wire                                          fired_neuron_address_valid,
    output reg                                           fired_neuron_address_acknowledge,

    // Global decay timer
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]              decay_timer_current_value,

    // Trace memory
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               trace_memory_read_neuron_address,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]              trace_memory_read_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]              trace_memory_read_stored_timestamp,
    input  wire                                          trace_memory_read_saturated_flag,
    output reg                                           trace_memory_write_enable,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               trace_memory_write_neuron_address,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]              trace_memory_write_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]              trace_memory_write_stored_timestamp,
    output reg                                           trace_memory_write_saturated_flag,

    // Trace update arbiter
    output reg                                           arbiter_request_valid,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               arbiter_request_neuron_address,
    output reg                                           arbiter_request_operation_type,
    output reg  [TRACE_VALUE_BIT_WIDTH-1:0]              arbiter_request_trace_value,
    output reg  [DECAY_TIMER_BIT_WIDTH-1:0]              arbiter_request_trace_stored_timestamp,
    output reg                                           arbiter_request_trace_saturated_flag,
    input  wire                                          arbiter_all_modules_busy_flag,
    input  wire                                          arbiter_idle_flag,
    input  wire                                          arbiter_result_valid,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]               arbiter_result_neuron_address,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]              arbiter_result_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]              arbiter_result_stored_timestamp,
    input  wire                                          arbiter_result_saturated_flag,
    input  wire                                          arbiter_result_operation_type,

    // Connection matrix
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               connection_matrix_read_row_address,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]            connection_matrix_row_input_vector,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]            connection_matrix_row_output_vector,
    input  wire                                          connection_matrix_row_data_valid,

    // Banked weight memory
    output reg                                           weight_bank_row_read_enable,
    output reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0]          weight_bank_row_read_address,
    input  wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]  weight_bank_row_weight_data_bus,
    input  wire                                          weight_bank_row_data_valid,
    output reg                                           weight_bank_column_read_enable,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               weight_bank_column_pre_neuron_address,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               weight_bank_column_step_counter,
    input  wire [WEIGHT_BIT_WIDTH-1:0]                   weight_bank_column_weight_output,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]               weight_bank_column_target_neuron_index,
    input  wire                                          weight_bank_column_data_valid,
    output reg  [NUM_WEIGHT_BANKS-1:0]                   weight_bank_write_enable_per_bank,
    output reg  [WEIGHT_BANK_ADDRESS_WIDTH-1:0]          weight_bank_write_address,
    output reg  [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]  weight_bank_write_data_bus,

    // Weight distribution bus
    output reg  [WEIGHT_BIT_WIDTH-1:0]                   weight_distribution_bus_data,
    output reg  [NEURON_ADDRESS_WIDTH-1:0]               weight_distribution_bus_target_neuron_address,
    output reg                                           weight_distribution_bus_valid,

    output reg                                           stdp_controller_busy_flag,
    output reg                                           transaction_timeout_flag
);

    localparam COUNT_WIDTH = $clog2(NUM_NEURONS_PER_CLUSTER + 1);

    localparam ST_IDLE  = 3'd0;
    localparam ST_SETUP = 3'd1;
    localparam ST_SCAN  = 3'd2;
    localparam ST_WAIT  = 3'd3;
    localparam ST_WRITE = 3'd4;

    reg [2:0] state_register;

    reg [NEURON_ADDRESS_WIDTH-1:0]    fired_address_register;
    reg [NUM_NEURONS_PER_CLUSTER-1:0] input_vector_register;
    reg [NUM_NEURONS_PER_CLUSTER-1:0] output_vector_register;

    reg [COUNT_WIDTH-1:0]             distribute_pointer_register;  // activity A
    reg [COUNT_WIDTH-1:0]             pre_trace_pointer_register;   // activity B
    reg                               activity_a_done_register;
    reg                               activity_b_done_register;

    // Activity B is a 1-deep pipeline: present the trace address in cycle k,
    // issue the arbiter request in cycle k+1 (trace memory reads are async).
    reg                               pre_trace_pipe_valid_register;
    reg [NEURON_ADDRESS_WIDTH-1:0]    pre_trace_pipe_address_register;

    reg [COUNT_WIDTH-1:0]             pending_trace_result_count_register;
    reg [COUNT_WIDTH-1:0]             received_trace_result_count_register;

    reg [TRACE_VALUE_BIT_WIDTH-1:0]   pre_synaptic_trace_result_store_register [0:NUM_NEURONS_PER_CLUSTER-1];
    reg [TRACE_VALUE_BIT_WIDTH-1:0]   post_synaptic_trace_result_register;

    reg [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] captured_row_weight_bus_register;
    reg                               row_captured_register;

    reg [$clog2(TRANSACTION_TIMEOUT+1)-1:0] watchdog_counter_register;

    // -------------------------------------------------------------------------
    // Combinational helpers
    // -------------------------------------------------------------------------

    // popcount of the connection matrix input vector (used only in SETUP)
    integer pc_idx;
    reg [COUNT_WIDTH-1:0] input_vector_popcount;
    always @(*) begin
        input_vector_popcount = {COUNT_WIDTH{1'b0}};
        for (pc_idx = 0; pc_idx < NUM_NEURONS_PER_CLUSTER; pc_idx = pc_idx + 1)
            if (connection_matrix_row_input_vector[pc_idx])
                input_vector_popcount = input_vector_popcount + 1'b1;
    end

    // PERFORMANCE: the set-bit scans used to be combinational 128-iteration
    // loops re-evaluated every clock. They are now flattened ONCE per
    // transaction into index lists, so ST_SCAN is a plain array lookup.
    reg [NEURON_ADDRESS_WIDTH-1:0] distribute_index_list [0:NUM_NEURONS_PER_CLUSTER-1];
    reg [COUNT_WIDTH-1:0]          distribute_index_count;
    reg [NEURON_ADDRESS_WIDTH-1:0] pre_trace_index_list  [0:NUM_NEURONS_PER_CLUSTER-1];
    reg [COUNT_WIDTH-1:0]          pre_trace_index_count;

    wire distribute_next_found = (distribute_pointer_register < distribute_index_count);
    wire pre_trace_next_found  = (pre_trace_pointer_register  < pre_trace_index_count);
    wire [NEURON_ADDRESS_WIDTH-1:0] distribute_next_index =
             distribute_index_list[distribute_pointer_register[NEURON_ADDRESS_WIDTH-1:0]];
    wire [NEURON_ADDRESS_WIDTH-1:0] pre_trace_next_index =
             pre_trace_index_list[pre_trace_pointer_register[NEURON_ADDRESS_WIDTH-1:0]];

    // De-skewed pre-synaptic trace bus. Registered (not combinational) so the
    // 128 parallel weight_update_logic instances are evaluated once per
    // transaction instead of once per arriving trace result.
    reg [NUM_WEIGHT_BANKS*TRACE_VALUE_BIT_WIDTH-1:0] pre_synaptic_trace_bus_for_update;

    // Write mask: bank b is written only if its pre-synaptic neuron is
    // actually connected to the fired neuron.
    integer wm_idx;
    reg [NUM_WEIGHT_BANKS-1:0] weight_write_mask;
    always @(*) begin
        for (wm_idx = 0; wm_idx < NUM_WEIGHT_BANKS; wm_idx = wm_idx + 1)
            weight_write_mask[wm_idx] =
                input_vector_register[(wm_idx - fired_address_register) & (NUM_WEIGHT_BANKS - 1)];
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
        .all_banks_current_weight_bus     (captured_row_weight_bus_register),
        .all_banks_updated_weight_bus     (updated_weight_bus_wire)
    );

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    integer rst_idx;
    integer list_idx;
    integer deskew_idx;
    reg [COUNT_WIDTH-1:0] list_count;
    reg     issued_request_this_cycle;

    always @(posedge clock) begin
        if (reset) begin
            state_register                       <= ST_IDLE;
            fired_neuron_address_acknowledge     <= 1'b0;
            trace_memory_read_neuron_address     <= {NEURON_ADDRESS_WIDTH{1'b0}};
            trace_memory_write_enable            <= 1'b0;
            trace_memory_write_neuron_address    <= {NEURON_ADDRESS_WIDTH{1'b0}};
            trace_memory_write_trace_value       <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            trace_memory_write_stored_timestamp  <= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            trace_memory_write_saturated_flag    <= 1'b0;
            arbiter_request_valid                <= 1'b0;
            arbiter_request_neuron_address        <= {NEURON_ADDRESS_WIDTH{1'b0}};
            arbiter_request_operation_type        <= 1'b0;
            arbiter_request_trace_value           <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            arbiter_request_trace_stored_timestamp<= {DECAY_TIMER_BIT_WIDTH{1'b0}};
            arbiter_request_trace_saturated_flag  <= 1'b0;
            connection_matrix_read_row_address    <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_row_read_enable           <= 1'b0;
            weight_bank_row_read_address          <= {WEIGHT_BANK_ADDRESS_WIDTH{1'b0}};
            weight_bank_column_read_enable        <= 1'b0;
            weight_bank_column_pre_neuron_address <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_column_step_counter       <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_bank_write_enable_per_bank     <= {NUM_WEIGHT_BANKS{1'b0}};
            weight_bank_write_address             <= {WEIGHT_BANK_ADDRESS_WIDTH{1'b0}};
            weight_bank_write_data_bus            <= {(NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH){1'b0}};
            weight_distribution_bus_data          <= {WEIGHT_BIT_WIDTH{1'b0}};
            weight_distribution_bus_target_neuron_address <= {NEURON_ADDRESS_WIDTH{1'b0}};
            weight_distribution_bus_valid         <= 1'b0;
            stdp_controller_busy_flag             <= 1'b0;
            transaction_timeout_flag              <= 1'b0;
            fired_address_register                <= {NEURON_ADDRESS_WIDTH{1'b0}};
            input_vector_register                 <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            output_vector_register                <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            distribute_pointer_register           <= {COUNT_WIDTH{1'b0}};
            pre_trace_pointer_register            <= {COUNT_WIDTH{1'b0}};
            activity_a_done_register              <= 1'b0;
            activity_b_done_register              <= 1'b0;
            pre_trace_pipe_valid_register         <= 1'b0;
            pre_trace_pipe_address_register       <= {NEURON_ADDRESS_WIDTH{1'b0}};
            pending_trace_result_count_register   <= {COUNT_WIDTH{1'b0}};
            received_trace_result_count_register  <= {COUNT_WIDTH{1'b0}};
            post_synaptic_trace_result_register   <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
            captured_row_weight_bus_register      <= {(NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH){1'b0}};
            row_captured_register                 <= 1'b0;
            watchdog_counter_register             <= 0;
            distribute_index_count                <= {COUNT_WIDTH{1'b0}};
            pre_trace_index_count                 <= {COUNT_WIDTH{1'b0}};
            pre_synaptic_trace_bus_for_update     <= {(NUM_WEIGHT_BANKS*TRACE_VALUE_BIT_WIDTH){1'b0}};
            for (rst_idx = 0; rst_idx < NUM_NEURONS_PER_CLUSTER; rst_idx = rst_idx + 1)
                pre_synaptic_trace_result_store_register[rst_idx] <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
        end else begin
            // ---- single-cycle strobes default low ----
            fired_neuron_address_acknowledge  <= 1'b0;
            trace_memory_write_enable         <= 1'b0;
            arbiter_request_valid             <= 1'b0;
            weight_bank_row_read_enable       <= 1'b0;
            weight_bank_column_read_enable    <= 1'b0;
            weight_bank_write_enable_per_bank <= {NUM_WEIGHT_BANKS{1'b0}};
            weight_distribution_bus_valid     <= 1'b0;

            issued_request_this_cycle = 1'b0;

            // ---- capture the row read whenever it lands ----
            if (weight_bank_row_data_valid && !row_captured_register &&
                state_register != ST_IDLE) begin
                captured_row_weight_bus_register <= weight_bank_row_weight_data_bus;
                row_captured_register            <= 1'b1;
            end

            // ---- accept trace results in any active state ----
            if (arbiter_result_valid && state_register != ST_IDLE) begin
                if (arbiter_result_operation_type == 1'b0)
                    post_synaptic_trace_result_register <= arbiter_result_trace_value;
                else
                    pre_synaptic_trace_result_store_register[arbiter_result_neuron_address]
                        <= arbiter_result_trace_value;

                // Persist the new trace state back to trace memory
                trace_memory_write_enable           <= 1'b1;
                trace_memory_write_neuron_address    <= arbiter_result_neuron_address;
                trace_memory_write_trace_value       <= arbiter_result_trace_value;
                trace_memory_write_stored_timestamp  <= arbiter_result_stored_timestamp;
                trace_memory_write_saturated_flag    <= arbiter_result_saturated_flag;

                received_trace_result_count_register <= received_trace_result_count_register + 1'b1;
            end

            // ---- watchdog ----
            if (state_register != ST_IDLE) begin
                if (watchdog_counter_register >= TRANSACTION_TIMEOUT) begin
                    transaction_timeout_flag  <= 1'b1;
                    state_register            <= ST_IDLE;
                    stdp_controller_busy_flag <= 1'b0;
                    watchdog_counter_register <= 0;
                end else begin
                    watchdog_counter_register <= watchdog_counter_register + 1'b1;
                end
            end

            case (state_register)

            // =================================================================
            ST_IDLE: begin
                stdp_controller_busy_flag <= 1'b0;
                watchdog_counter_register <= 0;
                // Wait for the arbiter to be completely drained before starting.
                // Otherwise a trace result issued by the PREVIOUS transaction
                // lands here, inflates received_trace_result_count_register, and
                // ST_WAIT exits before every pre-synaptic trace has been
                // refreshed -- leaving stale (potentiating) values in the result
                // store that are never overwritten again.
                if (fired_neuron_address_valid && arbiter_idle_flag) begin
                    fired_address_register           <= fired_neuron_address;
                    fired_neuron_address_acknowledge <= 1'b1;
                    stdp_controller_busy_flag        <= 1'b1;

                    // Present the connectivity row address AND the fired
                    // neuron's own trace address now; both are combinational
                    // reads, so SETUP sees settled data next cycle.
                    connection_matrix_read_row_address <= fired_neuron_address;
                    trace_memory_read_neuron_address   <= fired_neuron_address;

                    row_captured_register                <= 1'b0;
                    activity_a_done_register             <= 1'b0;
                    activity_b_done_register             <= 1'b0;
                    pre_trace_pipe_valid_register        <= 1'b0;
                    distribute_pointer_register          <= {COUNT_WIDTH{1'b0}};
                    pre_trace_pointer_register           <= {COUNT_WIDTH{1'b0}};
                    received_trace_result_count_register <= {COUNT_WIDTH{1'b0}};
                    post_synaptic_trace_result_register  <= {TRACE_VALUE_BIT_WIDTH{1'b0}};
                    // NOTE: pre_synaptic_trace_result_store_register is NOT
                    // cleared here. Every connected pre-synaptic slot is
                    // overwritten by this transaction's DECAY_COMPUTE results
                    // before ST_WRITE, and unconnected banks are excluded by
                    // weight_write_mask, so stale entries cannot be used.
                    state_register <= ST_SETUP;
                end
            end

            // =================================================================
            ST_SETUP: begin
                // Connectivity vectors are valid for fired_address_register.
                input_vector_register  <= connection_matrix_row_input_vector;
                output_vector_register <= connection_matrix_row_output_vector;

                // Flatten both connection vectors into index lists once.
                list_count = {COUNT_WIDTH{1'b0}};
                for (list_idx = 0; list_idx < NUM_NEURONS_PER_CLUSTER; list_idx = list_idx + 1) begin
                    if (connection_matrix_row_output_vector[list_idx]) begin
                        distribute_index_list[list_count] <= list_idx[NEURON_ADDRESS_WIDTH-1:0];
                        list_count = list_count + 1'b1;
                    end
                end
                distribute_index_count <= list_count;

                list_count = {COUNT_WIDTH{1'b0}};
                for (list_idx = 0; list_idx < NUM_NEURONS_PER_CLUSTER; list_idx = list_idx + 1) begin
                    if (connection_matrix_row_input_vector[list_idx]) begin
                        pre_trace_index_list[list_count] <= list_idx[NEURON_ADDRESS_WIDTH-1:0];
                        list_count = list_count + 1'b1;
                    end
                end
                pre_trace_index_count <= list_count;

                // Every connected pre-synaptic trace, plus this neuron's own
                // INCREASE, must come back before the weights can be written.
                pending_trace_result_count_register <= input_vector_popcount + 1'b1;

                // INCREASE this neuron's own trace
                arbiter_request_valid                  <= 1'b1;
                arbiter_request_neuron_address         <= fired_address_register;
                arbiter_request_operation_type         <= 1'b0;  // INCREASE
                arbiter_request_trace_value            <= trace_memory_read_trace_value;
                arbiter_request_trace_stored_timestamp <= trace_memory_read_stored_timestamp;
                arbiter_request_trace_saturated_flag   <= trace_memory_read_saturated_flag;

                // Fetch all incoming weights to this neuron for the update step
                weight_bank_row_read_enable  <= 1'b1;
                weight_bank_row_read_address <= fired_address_register;

                state_register <= ST_SCAN;
            end

            // =================================================================
            ST_SCAN: begin
                // ---- Activity A: weight distribution (inference path) ----
                // Column read issued last cycle lands now; forward it.
                if (weight_bank_column_data_valid) begin
                    weight_distribution_bus_valid                  <= 1'b1;
                    weight_distribution_bus_data                  <= weight_bank_column_weight_output;
                    weight_distribution_bus_target_neuron_address  <= weight_bank_column_target_neuron_index;
                end

                if (!activity_a_done_register) begin
                    if (distribute_next_found) begin
                        weight_bank_column_read_enable        <= 1'b1;
                        weight_bank_column_pre_neuron_address <= fired_address_register;
                        weight_bank_column_step_counter       <= distribute_next_index;
                        // advance by one LIST POSITION (not neuron index)
                        distribute_pointer_register           <= distribute_pointer_register + 1'b1;
                    end else begin
                        activity_a_done_register <= 1'b1;
                    end
                end

                // ---- Activity B: pre-synaptic trace fetch (learning path) ----
                // Stage 2: address presented last cycle is readable now.
                if (pre_trace_pipe_valid_register && !arbiter_all_modules_busy_flag) begin
                    arbiter_request_valid                  <= 1'b1;
                    arbiter_request_neuron_address         <= pre_trace_pipe_address_register;
                    arbiter_request_operation_type         <= 1'b1;  // DECAY_COMPUTE
                    arbiter_request_trace_value            <= trace_memory_read_trace_value;
                    arbiter_request_trace_stored_timestamp <= trace_memory_read_stored_timestamp;
                    arbiter_request_trace_saturated_flag   <= trace_memory_read_saturated_flag;
                    issued_request_this_cycle = 1'b1;
                end

                // Stage 1: load the next address only when stage 2 is free.
                if (issued_request_this_cycle || !pre_trace_pipe_valid_register) begin
                    if (!activity_b_done_register && pre_trace_next_found) begin
                        trace_memory_read_neuron_address <= pre_trace_next_index;
                        pre_trace_pipe_address_register  <= pre_trace_next_index;
                        pre_trace_pipe_valid_register    <= 1'b1;
                        // advance by one LIST POSITION (not neuron index)
                        pre_trace_pointer_register       <= pre_trace_pointer_register + 1'b1;
                    end else begin
                        pre_trace_pipe_valid_register <= 1'b0;
                        activity_b_done_register      <= 1'b1;
                    end
                end

                if (activity_a_done_register && activity_b_done_register &&
                    !pre_trace_pipe_valid_register)
                    state_register <= ST_WAIT;
            end

            // =================================================================
            ST_WAIT: begin
                // Trailing column read result still needs forwarding.
                if (weight_bank_column_data_valid) begin
                    weight_distribution_bus_valid                  <= 1'b1;
                    weight_distribution_bus_data                  <= weight_bank_column_weight_output;
                    weight_distribution_bus_target_neuron_address  <= weight_bank_column_target_neuron_index;
                end

                if (received_trace_result_count_register >= pending_trace_result_count_register &&
                    row_captured_register) begin
                    // Latch the de-skewed pre-synaptic traces: bank b at
                    // address f holds W(pre = (b - f) mod N, post = f).
                    for (deskew_idx = 0; deskew_idx < NUM_WEIGHT_BANKS; deskew_idx = deskew_idx + 1)
                        pre_synaptic_trace_bus_for_update[deskew_idx*TRACE_VALUE_BIT_WIDTH +: TRACE_VALUE_BIT_WIDTH]
                            <= pre_synaptic_trace_result_store_register[
                                   (deskew_idx - fired_address_register) & (NUM_WEIGHT_BANKS - 1)];
                    state_register <= ST_WRITE;
                end
            end

            // =================================================================
            ST_WRITE: begin
                if (learning_enable)
                    weight_bank_write_enable_per_bank <= weight_write_mask;
                weight_bank_write_address  <= fired_address_register;
                weight_bank_write_data_bus <= updated_weight_bus_wire;
                stdp_controller_busy_flag  <= 1'b0;
                state_register             <= ST_IDLE;
            end

            default: state_register <= ST_IDLE;
            endcase
        end
    end

endmodule
