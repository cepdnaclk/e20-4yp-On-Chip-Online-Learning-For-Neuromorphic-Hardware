// =============================================================================
// Module: spike_input_queue
// Description: Serialises simultaneous spikes from the neuron array into one
//              neuron address per STDP transaction. While the queue is
//              non-empty every neuron in the cluster is frozen so the network
//              state cannot advance mid-transaction.
//
// FIXES:
//   * Enqueue is now EDGE triggered. It used to enqueue on the LEVEL of
//     incoming_spike_bus, so a neuron holding its spike output high re-entered
//     the queue on every clock edge and the cluster never drained.
//   * The push/count bookkeeping is rewritten with a running blocking-assigned
//     count so entries can no longer be dropped or double-counted.
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

    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]  incoming_spike_bus,

    output wire                                cluster_freeze_enable,

    output wire [NEURON_ADDRESS_WIDTH-1:0]     dequeued_spike_neuron_address,
    output wire                                dequeued_spike_valid,
    input  wire                                dequeue_acknowledge,

    output wire                                queue_empty_flag,
    output wire                                queue_full_flag,
    output reg                                 queue_overflow_flag
);

    localparam PTR_WIDTH   = $clog2(SPIKE_QUEUE_DEPTH);
    localparam COUNT_WIDTH = $clog2(SPIKE_QUEUE_DEPTH + 1);

    reg [NEURON_ADDRESS_WIDTH-1:0] fifo_memory [0:SPIKE_QUEUE_DEPTH-1];
    reg [PTR_WIDTH-1:0]            head_pointer_register;
    reg [PTR_WIDTH-1:0]            tail_pointer_register;
    reg [COUNT_WIDTH-1:0]          entry_count_register;

    // Rising-edge detect on the spike bus
    reg  [NUM_NEURONS_PER_CLUSTER-1:0] previous_spike_bus_register;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] spike_rising_edges =
        incoming_spike_bus & ~previous_spike_bus_register;

    assign queue_empty_flag = (entry_count_register == 0);
    assign queue_full_flag  = (entry_count_register == SPIKE_QUEUE_DEPTH);

    assign dequeued_spike_neuron_address = fifo_memory[head_pointer_register];
    assign dequeued_spike_valid          = !queue_empty_flag;

    // Freeze the cluster while any spike is still queued or being consumed.
    reg cluster_freeze_enable_register;
    assign cluster_freeze_enable = cluster_freeze_enable_register | (|spike_rising_edges);

    integer scan_idx;
    reg [PTR_WIDTH-1:0]   tail_scratch;
    reg [COUNT_WIDTH-1:0] count_scratch;

    always @(posedge clock) begin
        if (reset) begin
            head_pointer_register          <= {PTR_WIDTH{1'b0}};
            tail_pointer_register          <= {PTR_WIDTH{1'b0}};
            entry_count_register           <= {COUNT_WIDTH{1'b0}};
            cluster_freeze_enable_register <= 1'b0;
            previous_spike_bus_register    <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            queue_overflow_flag            <= 1'b0;
        end else begin
            previous_spike_bus_register <= incoming_spike_bus;

            tail_scratch  = tail_pointer_register;
            count_scratch = entry_count_register;

            // ---- Dequeue first so a push in the same cycle sees the space ----
            if (dequeue_acknowledge && count_scratch != 0) begin
                head_pointer_register <= (head_pointer_register + 1'b1) % SPIKE_QUEUE_DEPTH;
                count_scratch = count_scratch - 1'b1;
            end

            // ---- Enqueue every rising edge, lowest neuron index first ----
            // PERFORMANCE: guarded -- most cycles have no spikes at all.
            if (|spike_rising_edges)
            for (scan_idx = 0; scan_idx < NUM_NEURONS_PER_CLUSTER; scan_idx = scan_idx + 1) begin
                if (spike_rising_edges[scan_idx]) begin
                    if (count_scratch < SPIKE_QUEUE_DEPTH) begin
                        fifo_memory[tail_scratch] <= scan_idx[NEURON_ADDRESS_WIDTH-1:0];
                        tail_scratch  = (tail_scratch + 1'b1) % SPIKE_QUEUE_DEPTH;
                        count_scratch = count_scratch + 1'b1;
                    end else begin
                        queue_overflow_flag <= 1'b1;
                    end
                end
            end

            tail_pointer_register <= tail_scratch;
            entry_count_register  <= count_scratch;

            cluster_freeze_enable_register <= (count_scratch != 0);
        end
    end

endmodule
