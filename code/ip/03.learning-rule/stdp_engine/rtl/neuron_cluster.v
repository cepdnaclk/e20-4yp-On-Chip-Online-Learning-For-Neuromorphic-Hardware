// =============================================================================
// Module: neuron_cluster
// Description: Top level for one STDP cluster: neuron array + weight memory +
//              trace subsystem + STDP controller + WTA lateral inhibition.
//
// DATA FLOW
// ---------
//   external_spike_input_bus / neuron spikes
//        -> spike_input_queue      (serialise to one address per transaction)
//        -> stdp_controller        (one transaction per spiking neuron)
//             |-- column read  --> weight_distribution bus --> receivers
//             |                    --> stdp_lif_neuron.input_spike (INFERENCE)
//             |-- row read + trace reads --> weight_update_logic_bank_array
//                                  --> banked_weight_memory writes (LEARNING)
//        -> lateral_inhibition_wta (winner-take-all across the output layer)
//
// WEIGHT STORAGE
// --------------
//   W(pre = p, post = t) lives at banked_weight_memory.bank_memory[(t+p) mod N][t]
//     row read  at address f -> every INCOMING weight of neuron f (one per bank)
//     column read step = t   -> the single weight from the fired neuron f to t
//
// Spec Reference: Section 4.14
// =============================================================================

`timescale 1ns/1ps

module neuron_cluster #(
    parameter NUM_NEURONS_PER_CLUSTER      = 64,
    parameter NEURON_ADDRESS_WIDTH         = $clog2(NUM_NEURONS_PER_CLUSTER),
    parameter NUM_WEIGHT_BANKS             = NUM_NEURONS_PER_CLUSTER,
    parameter WEIGHT_BANK_ADDRESS_WIDTH    = NEURON_ADDRESS_WIDTH,
    parameter WEIGHT_BIT_WIDTH             = 8,
    parameter TRACE_VALUE_BIT_WIDTH        = 8,
    parameter DECAY_TIMER_BIT_WIDTH        = 12,
    parameter TRACE_SATURATION_THRESHOLD   = 256,
    parameter DECAY_SHIFT_LOG2             = 0,
    parameter TRACE_INCREMENT_VALUE        = 32,
    parameter NUM_TRACE_UPDATE_MODULES     = 4,
    parameter SPIKE_QUEUE_DEPTH            = NUM_NEURONS_PER_CLUSTER,
    parameter LTP_SHIFT_AMOUNT             = 3,
    parameter LTD_SHIFT_AMOUNT             = 6,
    parameter INCREASE_MODE                = 0,

    // Neuron model
    parameter MEMBRANE_BIT_WIDTH           = 20,
    parameter BASE_THRESHOLD               = 4000,
    parameter MEMBRANE_LEAK_SHIFT          = 3,
    parameter REFRACTORY_CYCLES            = 8,
    parameter THETA_INCREMENT              = 128,
    parameter THETA_DECAY_SHIFT            = 5,

    // Winner-take-all group (the output / excitatory layer)
    parameter WTA_GROUP_START              = 0,
    parameter WTA_GROUP_END                = 0,
    parameter WTA_ENABLE                   = 0,
    parameter WTA_INHIBIT_CYCLES           = 16
)(
    input  wire                                clock,
    input  wire                                reset,
    input  wire                                global_cluster_enable,
    input  wire                                learning_enable,
    input  wire                                adaptation_enable,
    input  wire                                membrane_clear,
    input  wire                                decay_enable_pulse,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]  external_spike_input_bus,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]  cluster_spike_output_bus,
    output wire                                cluster_busy_flag,
    output wire                                queue_overflow_flag,
    output wire                                transaction_timeout_flag
);

    // ---- decay timer ----
    wire [DECAY_TIMER_BIT_WIDTH-1:0] decay_timer_current_value_wire;

    // ---- spike queue ----
    wire                            cluster_freeze_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0] dequeued_spike_neuron_address_wire;
    wire                            dequeued_spike_valid_wire;
    wire                            dequeue_acknowledge_wire;
    wire                            queue_empty_flag_wire;
    wire                            queue_full_flag_wire;

    // ---- controller <-> trace memory ----
    wire                             stdp_controller_busy_flag_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]  trace_mem_read_addr_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0] trace_mem_read_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] trace_mem_read_timestamp_wire;
    wire                             trace_mem_read_saturated_wire;
    wire                             trace_mem_write_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]  trace_mem_write_addr_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0] trace_mem_write_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] trace_mem_write_timestamp_wire;
    wire                             trace_mem_write_saturated_wire;

    // ---- controller <-> arbiter ----
    wire                             arb_request_valid_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]  arb_request_neuron_address_wire;
    wire                             arb_request_operation_type_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0] arb_request_trace_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] arb_request_trace_timestamp_wire;
    wire                             arb_request_trace_saturated_wire;
    wire                             arb_all_busy_wire;
    wire                             arb_idle_wire;
    wire                             arb_result_valid_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]  arb_result_neuron_address_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0] arb_result_trace_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0] arb_result_timestamp_wire;
    wire                             arb_result_saturated_wire;
    wire                             arb_result_operation_type_wire;

    // ---- controller <-> connection matrix ----
    wire [NEURON_ADDRESS_WIDTH-1:0]    conn_read_row_addr_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] conn_row_input_vector_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] conn_row_output_vector_wire;
    wire                               conn_row_data_valid_wire;

    // ---- controller <-> weight memory ----
    wire                                         wm_row_read_enable_wire;
    wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]         wm_row_read_address_wire;
    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] wm_row_weight_data_bus_wire;
    wire                                         wm_row_data_valid_wire;
    wire                                         wm_column_read_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]              wm_column_pre_neuron_addr_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]              wm_column_step_counter_wire;
    wire [WEIGHT_BIT_WIDTH-1:0]                  wm_column_weight_output_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]              wm_column_target_neuron_wire;
    wire                                         wm_column_data_valid_wire;
    wire [NUM_WEIGHT_BANKS-1:0]                  wm_write_enable_per_bank_wire;
    wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]         wm_write_address_wire;
    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0] wm_write_data_bus_wire;

    // ---- weight distribution bus ----
    wire [WEIGHT_BIT_WIDTH-1:0]     dist_bus_data_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0] dist_bus_target_addr_wire;
    wire                            dist_bus_valid_wire;

    // ---- neuron array ----
    wire [NUM_NEURONS_PER_CLUSTER-1:0] neuron_spike_output_wires;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] incoming_spike_bus_combined;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] lateral_inhibit_bus_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] fire_request_bus_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] fire_grant_bus_wire;
    wire [NUM_NEURONS_PER_CLUSTER*MEMBRANE_BIT_WIDTH-1:0] membrane_bus_wire;

    wire [WEIGHT_BIT_WIDTH-1:0] receiver_held_weight       [0:NUM_NEURONS_PER_CLUSTER-1];
    wire                        receiver_held_weight_valid [0:NUM_NEURONS_PER_CLUSTER-1];

    // Integration must NOT be gated by the freeze: weight distribution happens
    // during an STDP transaction, i.e. exactly while the cluster is frozen.
    // The freeze only defers *firing* so the spike set cannot change mid-drain.
    wire neuron_integrate_enable_wire = global_cluster_enable;
    wire neuron_fire_enable_wire      = global_cluster_enable & ~cluster_freeze_enable_wire;

    assign cluster_spike_output_bus    = neuron_spike_output_wires;
    assign cluster_busy_flag           = stdp_controller_busy_flag_wire | ~queue_empty_flag_wire;
    assign incoming_spike_bus_combined = neuron_spike_output_wires | external_spike_input_bus;

    global_decay_timer #(
        .DECAY_TIMER_BIT_WIDTH (DECAY_TIMER_BIT_WIDTH)
    ) decay_timer_inst (
        .clock                     (clock),
        .reset                     (reset),
        .decay_enable_pulse        (decay_enable_pulse),
        .decay_timer_current_value (decay_timer_current_value_wire)
    );

    trace_memory #(
        .NUM_NEURONS_PER_CLUSTER (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH    (NEURON_ADDRESS_WIDTH),
        .TRACE_VALUE_BIT_WIDTH   (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH   (DECAY_TIMER_BIT_WIDTH)
    ) trace_memory_inst (
        .clock                       (clock),
        .reset                       (reset),
        .read_neuron_address         (trace_mem_read_addr_wire),
        .read_trace_value            (trace_mem_read_value_wire),
        .read_trace_stored_timestamp (trace_mem_read_timestamp_wire),
        .read_trace_saturated_flag   (trace_mem_read_saturated_wire),
        .write_enable                (trace_mem_write_enable_wire),
        .write_neuron_address        (trace_mem_write_addr_wire),
        .write_trace_value           (trace_mem_write_value_wire),
        .write_trace_stored_timestamp(trace_mem_write_timestamp_wire),
        .write_trace_saturated_flag  (trace_mem_write_saturated_wire)
    );

    trace_update_arbiter #(
        .NUM_TRACE_UPDATE_MODULES   (NUM_TRACE_UPDATE_MODULES),
        .NEURON_ADDRESS_WIDTH       (NEURON_ADDRESS_WIDTH),
        .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
        .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
        .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
        .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
        .INCREASE_MODE              (INCREASE_MODE)
    ) trace_arbiter_inst (
        .clock                          (clock),
        .reset                          (reset),
        .request_valid                  (arb_request_valid_wire),
        .request_neuron_address         (arb_request_neuron_address_wire),
        .request_operation_type         (arb_request_operation_type_wire),
        .request_trace_value            (arb_request_trace_value_wire),
        .request_trace_stored_timestamp (arb_request_trace_timestamp_wire),
        .request_trace_saturated_flag   (arb_request_trace_saturated_wire),
        .decay_timer_current_value      (decay_timer_current_value_wire),
        .all_modules_busy_flag          (arb_all_busy_wire),
        .arbiter_idle_flag              (arb_idle_wire),
        .result_valid                   (arb_result_valid_wire),
        .result_neuron_address          (arb_result_neuron_address_wire),
        .result_trace_value             (arb_result_trace_value_wire),
        .result_trace_stored_timestamp  (arb_result_timestamp_wire),
        .result_trace_saturated_flag    (arb_result_saturated_wire),
        .result_operation_type          (arb_result_operation_type_wire)
    );

    cluster_connection_matrix #(
        .NUM_NEURONS_PER_CLUSTER (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH    (NEURON_ADDRESS_WIDTH)
    ) connection_matrix_inst (
        .clock                       (clock),
        .reset                       (reset),
        .read_row_neuron_address     (conn_read_row_addr_wire),
        .row_input_connection_vector (conn_row_input_vector_wire),
        .row_output_connection_vector(conn_row_output_vector_wire),
        .row_data_valid              (conn_row_data_valid_wire),
        .write_enable                (1'b0),
        .write_row_neuron_address    ({NEURON_ADDRESS_WIDTH{1'b0}}),
        .write_column_neuron_address ({NEURON_ADDRESS_WIDTH{1'b0}}),
        .write_connection_bits       (2'b00)
    );

    banked_weight_memory #(
        .NUM_WEIGHT_BANKS          (NUM_WEIGHT_BANKS),
        .WEIGHT_BANK_ADDRESS_WIDTH (WEIGHT_BANK_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH          (WEIGHT_BIT_WIDTH),
        .NEURON_ADDRESS_WIDTH      (NEURON_ADDRESS_WIDTH)
    ) weight_memory_inst (
        .clock                           (clock),
        .reset                           (reset),
        .row_read_enable                 (wm_row_read_enable_wire),
        .row_read_address                (wm_row_read_address_wire),
        .row_read_weight_data_bus        (wm_row_weight_data_bus_wire),
        .row_read_data_valid             (wm_row_data_valid_wire),
        .column_read_enable              (wm_column_read_enable_wire),
        .column_read_pre_neuron_address  (wm_column_pre_neuron_addr_wire),
        .column_read_step_counter        (wm_column_step_counter_wire),
        .column_read_weight_output       (wm_column_weight_output_wire),
        .column_read_target_neuron_index (wm_column_target_neuron_wire),
        .column_read_data_valid          (wm_column_data_valid_wire),
        .weight_write_enable_per_bank    (wm_write_enable_per_bank_wire),
        .weight_write_address            (wm_write_address_wire),
        .weight_write_data_bus           (wm_write_data_bus_wire)
    );

    spike_input_queue #(
        .NUM_NEURONS_PER_CLUSTER (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH    (NEURON_ADDRESS_WIDTH),
        .SPIKE_QUEUE_DEPTH       (SPIKE_QUEUE_DEPTH)
    ) spike_queue_inst (
        .clock                        (clock),
        .reset                        (reset),
        .incoming_spike_bus           (incoming_spike_bus_combined),
        .cluster_freeze_enable        (cluster_freeze_enable_wire),
        .dequeued_spike_neuron_address(dequeued_spike_neuron_address_wire),
        .dequeued_spike_valid         (dequeued_spike_valid_wire),
        .dequeue_acknowledge          (dequeue_acknowledge_wire),
        .queue_empty_flag             (queue_empty_flag_wire),
        .queue_full_flag              (queue_full_flag_wire),
        .queue_overflow_flag          (queue_overflow_flag)
    );

    stdp_controller #(
        .NUM_NEURONS_PER_CLUSTER   (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH      (NEURON_ADDRESS_WIDTH),
        .NUM_WEIGHT_BANKS          (NUM_WEIGHT_BANKS),
        .WEIGHT_BANK_ADDRESS_WIDTH (WEIGHT_BANK_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH          (WEIGHT_BIT_WIDTH),
        .TRACE_VALUE_BIT_WIDTH     (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH     (DECAY_TIMER_BIT_WIDTH),
        .LTP_SHIFT_AMOUNT          (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT          (LTD_SHIFT_AMOUNT)
    ) stdp_ctrl_inst (
        .clock                                        (clock),
        .reset                                        (reset),
        .learning_enable                              (learning_enable),
        .fired_neuron_address                         (dequeued_spike_neuron_address_wire),
        .fired_neuron_address_valid                   (dequeued_spike_valid_wire),
        .fired_neuron_address_acknowledge             (dequeue_acknowledge_wire),
        .decay_timer_current_value                    (decay_timer_current_value_wire),
        .trace_memory_read_neuron_address             (trace_mem_read_addr_wire),
        .trace_memory_read_trace_value                (trace_mem_read_value_wire),
        .trace_memory_read_stored_timestamp           (trace_mem_read_timestamp_wire),
        .trace_memory_read_saturated_flag             (trace_mem_read_saturated_wire),
        .trace_memory_write_enable                    (trace_mem_write_enable_wire),
        .trace_memory_write_neuron_address            (trace_mem_write_addr_wire),
        .trace_memory_write_trace_value               (trace_mem_write_value_wire),
        .trace_memory_write_stored_timestamp          (trace_mem_write_timestamp_wire),
        .trace_memory_write_saturated_flag            (trace_mem_write_saturated_wire),
        .arbiter_request_valid                        (arb_request_valid_wire),
        .arbiter_request_neuron_address               (arb_request_neuron_address_wire),
        .arbiter_request_operation_type               (arb_request_operation_type_wire),
        .arbiter_request_trace_value                  (arb_request_trace_value_wire),
        .arbiter_request_trace_stored_timestamp       (arb_request_trace_timestamp_wire),
        .arbiter_request_trace_saturated_flag         (arb_request_trace_saturated_wire),
        .arbiter_all_modules_busy_flag                (arb_all_busy_wire),
        .arbiter_idle_flag                            (arb_idle_wire),
        .arbiter_result_valid                         (arb_result_valid_wire),
        .arbiter_result_neuron_address                (arb_result_neuron_address_wire),
        .arbiter_result_trace_value                   (arb_result_trace_value_wire),
        .arbiter_result_stored_timestamp              (arb_result_timestamp_wire),
        .arbiter_result_saturated_flag                (arb_result_saturated_wire),
        .arbiter_result_operation_type                (arb_result_operation_type_wire),
        .connection_matrix_read_row_address            (conn_read_row_addr_wire),
        .connection_matrix_row_input_vector            (conn_row_input_vector_wire),
        .connection_matrix_row_output_vector           (conn_row_output_vector_wire),
        .connection_matrix_row_data_valid              (conn_row_data_valid_wire),
        .weight_bank_row_read_enable                   (wm_row_read_enable_wire),
        .weight_bank_row_read_address                  (wm_row_read_address_wire),
        .weight_bank_row_weight_data_bus               (wm_row_weight_data_bus_wire),
        .weight_bank_row_data_valid                    (wm_row_data_valid_wire),
        .weight_bank_column_read_enable                (wm_column_read_enable_wire),
        .weight_bank_column_pre_neuron_address         (wm_column_pre_neuron_addr_wire),
        .weight_bank_column_step_counter               (wm_column_step_counter_wire),
        .weight_bank_column_weight_output              (wm_column_weight_output_wire),
        .weight_bank_column_target_neuron_index        (wm_column_target_neuron_wire),
        .weight_bank_column_data_valid                 (wm_column_data_valid_wire),
        .weight_bank_write_enable_per_bank             (wm_write_enable_per_bank_wire),
        .weight_bank_write_address                     (wm_write_address_wire),
        .weight_bank_write_data_bus                    (wm_write_data_bus_wire),
        .weight_distribution_bus_data                  (dist_bus_data_wire),
        .weight_distribution_bus_target_neuron_address (dist_bus_target_addr_wire),
        .weight_distribution_bus_valid                 (dist_bus_valid_wire),
        .stdp_controller_busy_flag                     (stdp_controller_busy_flag_wire),
        .transaction_timeout_flag                      (transaction_timeout_flag)
    );

    // =========================================================================
    // Winner-take-all lateral inhibition across the output layer
    // =========================================================================
    generate
        if (WTA_ENABLE != 0) begin : gen_wta
            lateral_inhibition_wta #(
                .NUM_NEURONS_PER_CLUSTER (NUM_NEURONS_PER_CLUSTER),
                .MEMBRANE_BIT_WIDTH      (MEMBRANE_BIT_WIDTH),
                .GROUP_START             (WTA_GROUP_START),
                .GROUP_END               (WTA_GROUP_END),
                .INHIBIT_CYCLES          (WTA_INHIBIT_CYCLES)
            ) wta_inst (
                .clock            (clock),
                .reset            (reset),
                .enable           (global_cluster_enable),
                .fire_request_bus (fire_request_bus_wire),
                .membrane_bus     (membrane_bus_wire),
                .fire_grant_bus   (fire_grant_bus_wire),
                .inhibit_bus      (lateral_inhibit_bus_wire)
            );
        end else begin : gen_no_wta
            assign lateral_inhibit_bus_wire = {NUM_NEURONS_PER_CLUSTER{1'b0}};
            assign fire_grant_bus_wire      = {NUM_NEURONS_PER_CLUSTER{1'b1}};
        end
    endgenerate

    // =========================================================================
    // Weight distribution receivers + neurons
    // =========================================================================
    genvar ni;
    generate
        for (ni = 0; ni < NUM_NEURONS_PER_CLUSTER; ni = ni + 1) begin : gen_neurons

            weight_distribution_receiver #(
                .WEIGHT_BIT_WIDTH     (WEIGHT_BIT_WIDTH),
                .NEURON_ADDRESS_WIDTH (NEURON_ADDRESS_WIDTH),
                .THIS_NEURON_ADDRESS  (ni)
            ) weight_receiver_inst (
                .clock                                 (clock),
                .reset                                 (reset),
                .distribution_bus_weight_data          (dist_bus_data_wire),
                .distribution_bus_target_neuron_address(dist_bus_target_addr_wire),
                .distribution_bus_valid                (dist_bus_valid_wire),
                .held_weight_value                     (receiver_held_weight[ni]),
                .held_weight_valid_flag                (receiver_held_weight_valid[ni]),
                .weight_consumed_acknowledge           (receiver_held_weight_valid[ni])
            );

            stdp_lif_neuron #(
                .WEIGHT_BIT_WIDTH    (WEIGHT_BIT_WIDTH),
                .MEMBRANE_BIT_WIDTH  (MEMBRANE_BIT_WIDTH),
                .THRESHOLD_BIT_WIDTH (MEMBRANE_BIT_WIDTH),
                .BASE_THRESHOLD      (BASE_THRESHOLD),
                .MEMBRANE_LEAK_SHIFT (MEMBRANE_LEAK_SHIFT),
                .REFRACTORY_CYCLES   (REFRACTORY_CYCLES),
                .THETA_INCREMENT     (THETA_INCREMENT),
                .THETA_DECAY_SHIFT   (THETA_DECAY_SHIFT)
            ) neuron_inst (
                .clock              (clock),
                .reset              (reset),
                .enable             (neuron_integrate_enable_wire),
                .fire_enable        (neuron_fire_enable_wire),
                .leak_tick          (decay_enable_pulse),
                .adaptation_enable  (adaptation_enable),
                .input_spike        (receiver_held_weight_valid[ni]),
                .synaptic_weight    (receiver_held_weight[ni]),
                .force_inhibit      (lateral_inhibit_bus_wire[ni]),
                .fire_grant         (fire_grant_bus_wire[ni]),
                .membrane_clear     (membrane_clear),
                .fire_request       (fire_request_bus_wire[ni]),
                .spike_output       (neuron_spike_output_wires[ni]),
                .membrane_potential (membrane_bus_wire[ni*MEMBRANE_BIT_WIDTH +: MEMBRANE_BIT_WIDTH]),
                .adaptive_threshold ()
            );
        end
    endgenerate

endmodule
