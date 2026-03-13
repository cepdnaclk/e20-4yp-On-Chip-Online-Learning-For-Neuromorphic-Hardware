// =============================================================================
// Module: neuron_cluster
// Description: Top-level integration module for one complete cluster.
//              Instantiates the neuron core array and all supporting
//              subsystems for STDP-based online learning.
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
    parameter DECAY_SHIFT_LOG2             = 3,
    parameter TRACE_INCREMENT_VALUE        = 32,
    parameter NUM_TRACE_UPDATE_MODULES     = NUM_NEURONS_PER_CLUSTER,
    parameter SPIKE_QUEUE_DEPTH            = NUM_NEURONS_PER_CLUSTER,
    parameter LTP_SHIFT_AMOUNT             = 2,
    parameter LTD_SHIFT_AMOUNT             = 2,
    parameter INCREASE_MODE                = 0
)(
    input  wire                                clock,
    input  wire                                reset,
    input  wire                                global_cluster_enable,
    input  wire                                decay_enable_pulse,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]  external_spike_input_bus,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]  cluster_spike_output_bus,
    output wire                                cluster_busy_flag
);

    // =========================================================================
    // Internal wires
    // =========================================================================
    // Global decay timer
    wire [DECAY_TIMER_BIT_WIDTH-1:0] decay_timer_current_value_wire;

    // Spike queue
    wire                              cluster_freeze_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   dequeued_spike_neuron_address_wire;
    wire                              dequeued_spike_valid_wire;
    wire                              dequeue_acknowledge_wire;
    wire                              queue_empty_flag_wire;
    wire                              queue_full_flag_wire;

    // STDP controller
    wire                              stdp_controller_busy_flag_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   trace_mem_read_addr_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0]  trace_mem_read_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  trace_mem_read_timestamp_wire;
    wire                              trace_mem_read_saturated_wire;
    wire                              trace_mem_write_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   trace_mem_write_addr_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0]  trace_mem_write_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  trace_mem_write_timestamp_wire;
    wire                              trace_mem_write_saturated_wire;

    // Arbiter
    wire                              arb_request_valid_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   arb_request_neuron_address_wire;
    wire                              arb_request_operation_type_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0]  arb_request_trace_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  arb_request_trace_timestamp_wire;
    wire                              arb_request_trace_saturated_wire;
    wire                              arb_all_busy_wire;
    wire                              arb_result_valid_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   arb_result_neuron_address_wire;
    wire [TRACE_VALUE_BIT_WIDTH-1:0]  arb_result_trace_value_wire;
    wire [DECAY_TIMER_BIT_WIDTH-1:0]  arb_result_timestamp_wire;
    wire                              arb_result_saturated_wire;
    wire                              arb_result_operation_type_wire;

    // Connection matrix
    wire [NEURON_ADDRESS_WIDTH-1:0]   conn_read_row_addr_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] conn_row_input_vector_wire;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] conn_row_output_vector_wire;
    wire                              conn_row_data_valid_wire;

    // Weight memory
    wire                                                  wm_row_read_enable_wire;
    wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                  wm_row_read_address_wire;
    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]          wm_row_weight_data_bus_wire;
    wire                                                  wm_row_data_valid_wire;
    wire                                                  wm_column_read_enable_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]                       wm_column_pre_neuron_addr_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]                       wm_column_step_counter_wire;
    wire [WEIGHT_BIT_WIDTH-1:0]                           wm_column_weight_output_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]                       wm_column_target_neuron_wire;
    wire                                                  wm_column_data_valid_wire;
    wire [NUM_WEIGHT_BANKS-1:0]                           wm_write_enable_per_bank_wire;
    wire [WEIGHT_BANK_ADDRESS_WIDTH-1:0]                  wm_write_address_wire;
    wire [NUM_WEIGHT_BANKS*WEIGHT_BIT_WIDTH-1:0]          wm_write_data_bus_wire;

    // Weight distribution bus
    wire [WEIGHT_BIT_WIDTH-1:0]       dist_bus_data_wire;
    wire [NEURON_ADDRESS_WIDTH-1:0]   dist_bus_target_addr_wire;
    wire                              dist_bus_valid_wire;

    // Neuron signals
    wire [NUM_NEURONS_PER_CLUSTER-1:0] neuron_spike_output_wires;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] incoming_spike_bus_combined;

    // Weight distribution receiver outputs
    wire [WEIGHT_BIT_WIDTH-1:0]       receiver_held_weight      [0:NUM_NEURONS_PER_CLUSTER-1];
    wire                              receiver_held_weight_valid [0:NUM_NEURONS_PER_CLUSTER-1];

    // Neuron enable: global enable AND NOT freeze
    wire neuron_enable_wire = global_cluster_enable & ~cluster_freeze_enable_wire;

    // Cluster outputs
    assign cluster_spike_output_bus = neuron_spike_output_wires;
    assign cluster_busy_flag = stdp_controller_busy_flag_wire | ~queue_empty_flag_wire;

    // Combined spike bus for queue (neuron outputs only; external handled separately)
    assign incoming_spike_bus_combined = neuron_spike_output_wires | external_spike_input_bus;

    // =========================================================================
    // Global Decay Timer
    // =========================================================================
    global_decay_timer #(
        .DECAY_TIMER_BIT_WIDTH (DECAY_TIMER_BIT_WIDTH)
    ) decay_timer_inst (
        .clock                   (clock),
        .reset                   (reset),
        .decay_enable_pulse      (decay_enable_pulse),
        .decay_timer_current_value (decay_timer_current_value_wire)
    );

    // =========================================================================
    // Trace Memory
    // =========================================================================
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

    // =========================================================================
    // Trace Update Arbiter
    // =========================================================================
    trace_update_arbiter #(
        .NUM_TRACE_UPDATE_MODULES    (NUM_TRACE_UPDATE_MODULES),
        .NEURON_ADDRESS_WIDTH        (NEURON_ADDRESS_WIDTH),
        .TRACE_VALUE_BIT_WIDTH       (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH       (DECAY_TIMER_BIT_WIDTH),
        .TRACE_SATURATION_THRESHOLD  (TRACE_SATURATION_THRESHOLD),
        .DECAY_SHIFT_LOG2            (DECAY_SHIFT_LOG2),
        .TRACE_INCREMENT_VALUE       (TRACE_INCREMENT_VALUE),
        .INCREASE_MODE               (INCREASE_MODE)
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
        .result_valid                   (arb_result_valid_wire),
        .result_neuron_address          (arb_result_neuron_address_wire),
        .result_trace_value             (arb_result_trace_value_wire),
        .result_trace_stored_timestamp  (arb_result_timestamp_wire),
        .result_trace_saturated_flag    (arb_result_saturated_wire),
        .result_operation_type          (arb_result_operation_type_wire)
    );

    // =========================================================================
    // Cluster Connection Matrix
    // =========================================================================
    cluster_connection_matrix #(
        .NUM_NEURONS_PER_CLUSTER (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH    (NEURON_ADDRESS_WIDTH)
    ) connection_matrix_inst (
        .clock                      (clock),
        .reset                      (reset),
        .read_row_neuron_address    (conn_read_row_addr_wire),
        .row_input_connection_vector (conn_row_input_vector_wire),
        .row_output_connection_vector(conn_row_output_vector_wire),
        .row_data_valid             (conn_row_data_valid_wire),
        .write_enable               (1'b0),  // External write port — tied off for now
        .write_row_neuron_address   ({NEURON_ADDRESS_WIDTH{1'b0}}),
        .write_column_neuron_address({NEURON_ADDRESS_WIDTH{1'b0}}),
        .write_connection_bits      (2'b00)
    );

    // =========================================================================
    // Banked Weight Memory
    // =========================================================================
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

    // =========================================================================
    // Spike Input Queue
    // =========================================================================
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
        .queue_full_flag              (queue_full_flag_wire)
    );

    // =========================================================================
    // STDP Controller
    // =========================================================================
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
        .clock                                      (clock),
        .reset                                      (reset),
        .fired_neuron_address                       (dequeued_spike_neuron_address_wire),
        .fired_neuron_address_valid                 (dequeued_spike_valid_wire),
        .fired_neuron_address_acknowledge           (dequeue_acknowledge_wire),
        .decay_timer_current_value                  (decay_timer_current_value_wire),
        .trace_memory_read_neuron_address           (trace_mem_read_addr_wire),
        .trace_memory_read_trace_value              (trace_mem_read_value_wire),
        .trace_memory_read_stored_timestamp         (trace_mem_read_timestamp_wire),
        .trace_memory_read_saturated_flag           (trace_mem_read_saturated_wire),
        .trace_memory_write_enable                  (trace_mem_write_enable_wire),
        .trace_memory_write_neuron_address          (trace_mem_write_addr_wire),
        .trace_memory_write_trace_value             (trace_mem_write_value_wire),
        .trace_memory_write_stored_timestamp        (trace_mem_write_timestamp_wire),
        .trace_memory_write_saturated_flag          (trace_mem_write_saturated_wire),
        .arbiter_request_valid                      (arb_request_valid_wire),
        .arbiter_request_neuron_address             (arb_request_neuron_address_wire),
        .arbiter_request_operation_type             (arb_request_operation_type_wire),
        .arbiter_request_trace_value                (arb_request_trace_value_wire),
        .arbiter_request_trace_stored_timestamp     (arb_request_trace_timestamp_wire),
        .arbiter_request_trace_saturated_flag       (arb_request_trace_saturated_wire),
        .arbiter_all_modules_busy_flag              (arb_all_busy_wire),
        .arbiter_result_valid                       (arb_result_valid_wire),
        .arbiter_result_neuron_address              (arb_result_neuron_address_wire),
        .arbiter_result_trace_value                 (arb_result_trace_value_wire),
        .arbiter_result_stored_timestamp            (arb_result_timestamp_wire),
        .arbiter_result_saturated_flag              (arb_result_saturated_wire),
        .arbiter_result_operation_type              (arb_result_operation_type_wire),
        .connection_matrix_read_row_address         (conn_read_row_addr_wire),
        .connection_matrix_row_input_vector         (conn_row_input_vector_wire),
        .connection_matrix_row_output_vector        (conn_row_output_vector_wire),
        .connection_matrix_row_data_valid           (conn_row_data_valid_wire),
        .weight_bank_row_read_enable                (wm_row_read_enable_wire),
        .weight_bank_row_read_address               (wm_row_read_address_wire),
        .weight_bank_row_weight_data_bus            (wm_row_weight_data_bus_wire),
        .weight_bank_row_data_valid                 (wm_row_data_valid_wire),
        .weight_bank_column_read_enable             (wm_column_read_enable_wire),
        .weight_bank_column_pre_neuron_address      (wm_column_pre_neuron_addr_wire),
        .weight_bank_column_step_counter            (wm_column_step_counter_wire),
        .weight_bank_column_weight_output           (wm_column_weight_output_wire),
        .weight_bank_column_target_neuron_index     (wm_column_target_neuron_wire),
        .weight_bank_column_data_valid              (wm_column_data_valid_wire),
        .weight_bank_write_enable_per_bank          (wm_write_enable_per_bank_wire),
        .weight_bank_write_address                  (wm_write_address_wire),
        .weight_bank_write_data_bus                 (wm_write_data_bus_wire),
        .weight_distribution_bus_data               (dist_bus_data_wire),
        .weight_distribution_bus_target_neuron_address (dist_bus_target_addr_wire),
        .weight_distribution_bus_valid              (dist_bus_valid_wire),
        .stdp_controller_busy_flag                  (stdp_controller_busy_flag_wire)
    );

    // =========================================================================
    // Weight Distribution Receivers + Neuron Instances
    // =========================================================================
    genvar ni;
    generate
        for (ni = 0; ni < NUM_NEURONS_PER_CLUSTER; ni = ni + 1) begin : gen_neurons

            weight_distribution_receiver #(
                .WEIGHT_BIT_WIDTH     (WEIGHT_BIT_WIDTH),
                .NEURON_ADDRESS_WIDTH (NEURON_ADDRESS_WIDTH),
                .THIS_NEURON_ADDRESS  (ni)
            ) weight_receiver_inst (
                .clock                                (clock),
                .reset                                (reset),
                .distribution_bus_weight_data         (dist_bus_data_wire),
                .distribution_bus_target_neuron_address(dist_bus_target_addr_wire),
                .distribution_bus_valid               (dist_bus_valid_wire),
                .held_weight_value                    (receiver_held_weight[ni]),
                .held_weight_valid_flag               (receiver_held_weight_valid[ni]),
                .weight_consumed_acknowledge          (receiver_held_weight_valid[ni]) // auto-ack on valid
            );

            // Neuron instance
            // Assumes neuron model has: clock, reset, enable,
            //   input_spike_wire, weight_input[WEIGHT_BIT_WIDTH-1:0], spike_output_wire
            simple_LIF_Neuron_Model neuron_inst (
                .clock               (clock),
                .reset               (reset),
                .enable              (neuron_enable_wire),
                .input_spike_wire    (receiver_held_weight_valid[ni]),
                .synaptic_weight_wire        (receiver_held_weight[ni]),
                .spike_output_wire   (neuron_spike_output_wires[ni])
            );
        end
    endgenerate

endmodule
