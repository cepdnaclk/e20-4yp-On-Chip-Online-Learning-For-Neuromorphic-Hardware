// =============================================================================
// Module: spike_input_queue
// Description: Handles simultaneous spikes from multiple neurons.
//              Enqueues as binary addresses and releases one at a time
//              to the STDP controller. While non-empty, all cluster
//              neurons are frozen via cluster_freeze_enable.
// Spec Reference: Section 4.11
// =============================================================================

`timescale 1ns/1ps

module spike_input_queue #(
    parameter NUM_NEURONS_PER_CLUSTER = 64,
    parameter NEURON_ADDRESS_WIDTH    = $clog2(NUM_NEURONS_PER_CLUSTER),
    parameter SPIKE_QUEUE_DEPTH       = 64
)(
    input  wire                                clock,
    input  wire                                reset,

    // Spike bus from neuron array
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]  incoming_spike_bus,

    // Freeze control
    output wire                                cluster_freeze_enable,

    // Dequeue interface (to STDP controller)
    output wire [NEURON_ADDRESS_WIDTH-1:0]     dequeued_spike_neuron_address,
    output wire                                dequeued_spike_valid,
    input  wire                                dequeue_acknowledge,

    // Status flags
    output wire                                queue_empty_flag,
    output wire                                queue_full_flag
);

    localparam QUEUE_PTR_WIDTH = $clog2(SPIKE_QUEUE_DEPTH);
    localparam COUNT_WIDTH     = $clog2(SPIKE_QUEUE_DEPTH + 1);

    // Circular buffer
    reg [NEURON_ADDRESS_WIDTH-1:0] fifo_memory [0:SPIKE_QUEUE_DEPTH-1];
    reg [QUEUE_PTR_WIDTH-1:0]      head_pointer_register;
    reg [QUEUE_PTR_WIDTH-1:0]      tail_pointer_register;
    reg [COUNT_WIDTH-1:0]          entry_count_register;

    assign queue_empty_flag = (entry_count_register == 0);
    assign queue_full_flag  = (entry_count_register == SPIKE_QUEUE_DEPTH);

    // cluster_freeze_enable is registered to prevent glitches (spec §4.11)
    reg cluster_freeze_enable_register;
    assign cluster_freeze_enable = cluster_freeze_enable_register;

    // FIFO head visible when non-empty
    assign dequeued_spike_neuron_address = fifo_memory[head_pointer_register];
    assign dequeued_spike_valid          = !queue_empty_flag;

    // Enqueue logic: combinational scan of incoming_spike_bus
    // Push spikes from lowest index to highest in one cycle
    integer scan_idx;
    reg [COUNT_WIDTH-1:0]     enqueue_count;
    reg [NEURON_ADDRESS_WIDTH-1:0] enqueue_addresses [0:NUM_NEURONS_PER_CLUSTER-1];

    always @(*) begin
        enqueue_count = 0;
        for (scan_idx = 0; scan_idx < NUM_NEURONS_PER_CLUSTER; scan_idx = scan_idx + 1) begin
            enqueue_addresses[scan_idx] = {NEURON_ADDRESS_WIDTH{1'b0}};
        end
        for (scan_idx = 0; scan_idx < NUM_NEURONS_PER_CLUSTER; scan_idx = scan_idx + 1) begin
            if (incoming_spike_bus[scan_idx]) begin
                enqueue_addresses[enqueue_count] = scan_idx[NEURON_ADDRESS_WIDTH-1:0];
                enqueue_count = enqueue_count + 1;
            end
        end
    end

    integer push_idx;
    always @(posedge clock) begin
        if (reset) begin
            head_pointer_register          <= {QUEUE_PTR_WIDTH{1'b0}};
            tail_pointer_register          <= {QUEUE_PTR_WIDTH{1'b0}};
            entry_count_register           <= {COUNT_WIDTH{1'b0}};
            cluster_freeze_enable_register <= 1'b0;
        end else begin
            // Dequeue on acknowledge
            if (dequeue_acknowledge && !queue_empty_flag) begin
                head_pointer_register <= (head_pointer_register + 1) % SPIKE_QUEUE_DEPTH;
                entry_count_register  <= entry_count_register - 1;
            end

            // Enqueue all detected spikes (up to available space)
            for (push_idx = 0; push_idx < NUM_NEURONS_PER_CLUSTER; push_idx = push_idx + 1) begin
                if (push_idx < enqueue_count && !queue_full_flag &&
                    (entry_count_register + push_idx - (dequeue_acknowledge && !queue_empty_flag ? 1 : 0)) < SPIKE_QUEUE_DEPTH) begin
                    fifo_memory[(tail_pointer_register + push_idx) % SPIKE_QUEUE_DEPTH] <= enqueue_addresses[push_idx];
                end
            end

            // Update tail and count for pushes
            if (enqueue_count > 0) begin
                // Actual pushes limited by available space
                if (entry_count_register + enqueue_count - (dequeue_acknowledge && !queue_empty_flag ? 1 : 0) <= SPIKE_QUEUE_DEPTH) begin
                    tail_pointer_register <= (tail_pointer_register + enqueue_count) % SPIKE_QUEUE_DEPTH;
                    entry_count_register  <= entry_count_register + enqueue_count
                                            - (dequeue_acknowledge && !queue_empty_flag ? 1 : 0);
                end
            end else if (dequeue_acknowledge && !queue_empty_flag) begin
                // Already handled above but entry_count needs update when no enqueue
                // (handled by the dequeue block)
            end

            // Update freeze (registered)
            // Freeze is active when queue will be non-empty next cycle
            if (entry_count_register + enqueue_count - (dequeue_acknowledge && !queue_empty_flag ? 1 : 0) > 0) begin
                cluster_freeze_enable_register <= 1'b1;
            end else begin
                cluster_freeze_enable_register <= 1'b0;
            end
        end
    end

endmodule
