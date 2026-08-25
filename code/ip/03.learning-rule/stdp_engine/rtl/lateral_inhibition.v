// =============================================================================
// Module: lateral_inhibition_wta
// Description: Competitive winner-take-all arbiter over a contiguous group of
//              neurons (the excitatory / output layer).
//
//              Neurons raise fire_request combinationally when their membrane
//              has reached threshold. In any cycle where one or more group
//              neurons request, exactly ONE grant is issued -- to the requester
//              with the HIGHEST membrane potential, i.e. the neuron whose
//              learned weights best match the current input. Every other
//              requester is inhibited: membrane wiped, forced into refractory.
//
// WHY ARBITRATION MUST BE COMBINATIONAL
//   The cluster freezes firing while the spike queue drains, so many
//   excitatory neurons sit above threshold at once and would all fire on the
//   very cycle the freeze lifts. A WTA that only inhibits *after* observing a
//   spike is too late -- every neuron already spiked, every neuron got
//   identical LTP, and the layer learned one identical receptive field.
//
// TIE BREAKING
//   Equal membranes are resolved by a priority origin that advances after every
//   grant, so a fixed lowest-index-wins bias cannot collapse the layer onto a
//   single neuron before the weights have differentiated.
// =============================================================================

`timescale 1ns/1ps

module lateral_inhibition_wta #(
    parameter NUM_NEURONS_PER_CLUSTER = 256,
    parameter MEMBRANE_BIT_WIDTH      = 20,
    parameter GROUP_START             = 200,
    parameter GROUP_END               = 239,
    parameter INHIBIT_CYCLES          = 8,
    parameter COUNTER_BIT_WIDTH       = 8
)(
    input  wire                                                clock,
    input  wire                                                reset,
    input  wire                                                enable,
    input  wire [NUM_NEURONS_PER_CLUSTER-1:0]                  fire_request_bus,
    input  wire [NUM_NEURONS_PER_CLUSTER*MEMBRANE_BIT_WIDTH-1:0] membrane_bus,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]                  fire_grant_bus,
    output wire [NUM_NEURONS_PER_CLUSTER-1:0]                  inhibit_bus
);

    localparam PTR_WIDTH = $clog2(NUM_NEURONS_PER_CLUSTER);

    // Static mask of the WTA group
    reg [NUM_NEURONS_PER_CLUSTER-1:0] group_mask;
    integer mask_idx;
    initial begin
        group_mask = {NUM_NEURONS_PER_CLUSTER{1'b0}};
        for (mask_idx = 0; mask_idx < NUM_NEURONS_PER_CLUSTER; mask_idx = mask_idx + 1)
            if (mask_idx >= GROUP_START && mask_idx <= GROUP_END)
                group_mask[mask_idx] = 1'b1;
    end

    wire [NUM_NEURONS_PER_CLUSTER-1:0] group_requests = fire_request_bus & group_mask;

    reg [PTR_WIDTH-1:0] priority_base_register;

    // ---- combinational max-membrane arbitration ----
    reg [NUM_NEURONS_PER_CLUSTER-1:0] winner_one_hot;
    reg                               winner_found;
    reg [MEMBRANE_BIT_WIDTH-1:0]      best_membrane;
    reg [MEMBRANE_BIT_WIDTH-1:0]      candidate_membrane;
    integer scan_i, rot_i;

    always @(*) begin
        winner_one_hot = {NUM_NEURONS_PER_CLUSTER{1'b0}};
        winner_found   = 1'b0;
        best_membrane  = {MEMBRANE_BIT_WIDTH{1'b0}};
        // PERFORMANCE: membrane_bus changes every cycle, so the scan is
        // guarded on there actually being a request to arbitrate.
        if (|group_requests)
        for (scan_i = 0; scan_i < NUM_NEURONS_PER_CLUSTER; scan_i = scan_i + 1) begin
            rot_i = (scan_i + priority_base_register) % NUM_NEURONS_PER_CLUSTER;
            if (group_requests[rot_i]) begin
                candidate_membrane = membrane_bus[rot_i*MEMBRANE_BIT_WIDTH +: MEMBRANE_BIT_WIDTH];
                if (!winner_found || candidate_membrane > best_membrane) begin
                    winner_one_hot = {NUM_NEURONS_PER_CLUSTER{1'b0}};
                    winner_one_hot[rot_i] = 1'b1;
                    best_membrane  = candidate_membrane;
                    winner_found   = 1'b1;
                end
            end
        end
    end

    reg [NUM_NEURONS_PER_CLUSTER-1:0] latched_winner_register;
    reg [COUNTER_BIT_WIDTH-1:0]       inhibit_counter_register;

    // Neurons outside the group are always free to fire.
    assign fire_grant_bus = ~group_mask | winner_one_hot;

    // Losers this cycle, plus the tail of the inhibition window.
    assign inhibit_bus = (group_requests & ~winner_one_hot) |
                         ((inhibit_counter_register != 0)
                            ? (group_mask & ~latched_winner_register)
                            : {NUM_NEURONS_PER_CLUSTER{1'b0}});

    always @(posedge clock) begin
        if (reset) begin
            latched_winner_register  <= {NUM_NEURONS_PER_CLUSTER{1'b0}};
            inhibit_counter_register <= {COUNTER_BIT_WIDTH{1'b0}};
            priority_base_register   <= GROUP_START[PTR_WIDTH-1:0];
        end else if (!enable) begin
            inhibit_counter_register <= {COUNTER_BIT_WIDTH{1'b0}};
        end else if (winner_found) begin
            latched_winner_register  <= winner_one_hot;
            inhibit_counter_register <= INHIBIT_CYCLES[COUNTER_BIT_WIDTH-1:0];
            if (priority_base_register >= GROUP_END[PTR_WIDTH-1:0])
                priority_base_register <= GROUP_START[PTR_WIDTH-1:0];
            else
                priority_base_register <= priority_base_register + 1'b1;
        end else if (inhibit_counter_register != 0) begin
            inhibit_counter_register <= inhibit_counter_register - 1'b1;
        end
    end

endmodule
