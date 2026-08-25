// =============================================================================
// Module: trace_memory
// Description: Stores one 21-bit trace entry per neuron.
//              Async (combinational) read, synchronous write.
//              Entry layout: [20] saturated_flag, [19:8] timestamp, [7:0] value
// Spec Reference: Section 4.2
// =============================================================================

`timescale 1ns/1ps

module trace_memory #(
    parameter NUM_NEURONS_PER_CLUSTER  = 64,
    parameter NEURON_ADDRESS_WIDTH     = $clog2(NUM_NEURONS_PER_CLUSTER),
    parameter TRACE_VALUE_BIT_WIDTH    = 8,
    parameter DECAY_TIMER_BIT_WIDTH    = 12
)(
    input  wire                                clock,
    input  wire                                reset,

    // Read port (asynchronous / combinational)
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     read_neuron_address,
    output wire [TRACE_VALUE_BIT_WIDTH-1:0]    read_trace_value,
    output wire [DECAY_TIMER_BIT_WIDTH-1:0]    read_trace_stored_timestamp,
    output wire                                read_trace_saturated_flag,

    // Write port (synchronous)
    input  wire                                write_enable,
    input  wire [NEURON_ADDRESS_WIDTH-1:0]     write_neuron_address,
    input  wire [TRACE_VALUE_BIT_WIDTH-1:0]    write_trace_value,
    input  wire [DECAY_TIMER_BIT_WIDTH-1:0]    write_trace_stored_timestamp,
    input  wire                                write_trace_saturated_flag
);

    // Total entry width: 1 + DECAY_TIMER_BIT_WIDTH + TRACE_VALUE_BIT_WIDTH = 21 bits
    localparam ENTRY_WIDTH = 1 + DECAY_TIMER_BIT_WIDTH + TRACE_VALUE_BIT_WIDTH;

    // Storage array
    reg [ENTRY_WIDTH-1:0] trace_entries [0:NUM_NEURONS_PER_CLUSTER-1];

    // Asynchronous read: combinational outputs
    assign read_trace_value            = trace_entries[read_neuron_address][TRACE_VALUE_BIT_WIDTH-1:0];
    assign read_trace_stored_timestamp = trace_entries[read_neuron_address][DECAY_TIMER_BIT_WIDTH+TRACE_VALUE_BIT_WIDTH-1:TRACE_VALUE_BIT_WIDTH];
    assign read_trace_saturated_flag   = trace_entries[read_neuron_address][ENTRY_WIDTH-1];

    // Synchronous write and reset
    integer init_index;
    always @(posedge clock) begin
        if (reset) begin
            for (init_index = 0; init_index < NUM_NEURONS_PER_CLUSTER; init_index = init_index + 1) begin
                // saturated_flag=1, timestamp=0, value=0
                trace_entries[init_index] <= {1'b1, {DECAY_TIMER_BIT_WIDTH{1'b0}}, {TRACE_VALUE_BIT_WIDTH{1'b0}}};
            end
        end else if (write_enable) begin
            trace_entries[write_neuron_address] <= {write_trace_saturated_flag,
                                                    write_trace_stored_timestamp,
                                                    write_trace_value};
        end
    end

endmodule
