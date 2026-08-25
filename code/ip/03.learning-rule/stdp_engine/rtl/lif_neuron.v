// =============================================================================
// Module: stdp_lif_neuron
// Description: Synchronous leaky integrate-and-fire neuron with refractory
//              period and an adaptive (homeostatic) threshold.
//
//              This replaces simple_LIF_Neuron_Model for the STDP cluster.
//              The original IP neuron could not be used here because:
//                * its always block was sensitive to
//                  (posedge clock or posedge reset or posedge input_spike)
//                  and mixed blocking/non-blocking assignments,
//                * its threshold was incremented on every output spike and
//                  never decayed, so a neuron went permanently silent after
//                  a handful of spikes,
//                * spike_output_reg was held high for a whole 297-cycle time
//                  window, so the cluster spike queue re-enqueued the same
//                  neuron on every clock edge and never drained.
//
//              Contract here: spike_output is a ONE CYCLE pulse.
//
// Dynamics (all integer, no multipliers):
//   v      += synaptic_weight            on input_spike
//   v      -= v >> MEMBRANE_LEAK_SHIFT   on leak_tick
//   theta  -= theta >> THETA_DECAY_SHIFT on leak_tick   (adaptive threshold)
//   fire when v >= BASE_THRESHOLD + theta
//     -> v = 0, theta += THETA_INCREMENT, refractory = REFRACTORY_CYCLES
// =============================================================================

`timescale 1ns/1ps

module stdp_lif_neuron #(
    parameter WEIGHT_BIT_WIDTH      = 8,
    parameter MEMBRANE_BIT_WIDTH    = 20,
    parameter THRESHOLD_BIT_WIDTH   = 20,
    parameter BASE_THRESHOLD        = 4000,
    parameter MEMBRANE_LEAK_SHIFT   = 3,   // v -= v>>3  (12.5% per leak tick)
    parameter REFRACTORY_CYCLES     = 8,
    parameter THETA_INCREMENT       = 128, // homeostasis step on each spike
    parameter THETA_DECAY_SHIFT     = 5,   // theta -= theta>>5 per leak tick
    parameter REFRACTORY_BIT_WIDTH  = 8
)(
    input  wire                          clock,
    input  wire                          reset,

    input  wire                          enable,          // 0 = freeze integration
    input  wire                          fire_enable,     // 0 = defer firing (cluster frozen)
    input  wire                          leak_tick,       // 1-cycle pulse
    input  wire                          adaptation_enable, // 0 = freeze theta

    input  wire                          input_spike,     // 1-cycle pulse
    input  wire [WEIGHT_BIT_WIDTH-1:0]   synaptic_weight,

    input  wire                          force_inhibit,   // WTA: lost the competition
    input  wire                          fire_grant,      // WTA: cleared to spike
    input  wire                          membrane_clear,  // between-image reset
    output wire                          fire_request,    // combinational "at threshold"

    output wire                          spike_output,    // 1-cycle pulse
    output wire [MEMBRANE_BIT_WIDTH-1:0] membrane_potential,
    output wire [THRESHOLD_BIT_WIDTH-1:0] adaptive_threshold
);

    localparam [MEMBRANE_BIT_WIDTH-1:0] MEMBRANE_MAX = {MEMBRANE_BIT_WIDTH{1'b1}};

    reg [MEMBRANE_BIT_WIDTH-1:0]   membrane_potential_register;
    reg [THRESHOLD_BIT_WIDTH-1:0]  adaptive_threshold_register;
    reg [REFRACTORY_BIT_WIDTH-1:0] refractory_counter_register;
    reg                            spike_output_register;

    assign spike_output       = spike_output_register;
    assign membrane_potential = membrane_potential_register;
    assign adaptive_threshold = adaptive_threshold_register;

    // Effective firing threshold = fixed base + homeostatic offset
    wire [THRESHOLD_BIT_WIDTH:0] effective_threshold =
        BASE_THRESHOLD[THRESHOLD_BIT_WIDTH:0] + {1'b0, adaptive_threshold_register};

    // ---- Combinational next-membrane computation -------------------------
    reg [MEMBRANE_BIT_WIDTH+1:0] membrane_after_input;
    reg [MEMBRANE_BIT_WIDTH+1:0] membrane_after_leak;

    always @(*) begin
        membrane_after_input = {2'b00, membrane_potential_register};
        if (input_spike)
            membrane_after_input = membrane_after_input +
                                   {{(MEMBRANE_BIT_WIDTH+2-WEIGHT_BIT_WIDTH){1'b0}}, synaptic_weight};
        // saturate
        if (membrane_after_input > {2'b00, MEMBRANE_MAX})
            membrane_after_input = {2'b00, MEMBRANE_MAX};

        membrane_after_leak = membrane_after_input;
        if (leak_tick)
            membrane_after_leak = membrane_after_input -
                                  (membrane_after_input >> MEMBRANE_LEAK_SHIFT);
    end

    wire fires = (membrane_after_leak >= {1'b0, effective_threshold});

    // Combinational request to the WTA arbiter. Arbitration has to happen in
    // the SAME cycle the neuron would fire, otherwise every neuron sitting
    // above threshold spikes together the instant the cluster unfreezes.
    // NOTE: force_inhibit is deliberately NOT in this expression. inhibit_bus
    // is derived from fire_request_bus inside the arbiter, so including it
    // here would close a combinational loop. A losing neuron is stopped by
    // fire_grant (and has its membrane wiped by force_inhibit at the clock
    // edge), which is sufficient.
    assign fire_request = enable & fire_enable & ~membrane_clear &
                          (refractory_counter_register == 0) & fires;

    // ---- Combinational next-theta ----------------------------------------
    reg [THRESHOLD_BIT_WIDTH:0] theta_after_decay;
    always @(*) begin
        theta_after_decay = {1'b0, adaptive_threshold_register};
        if (leak_tick && adaptation_enable)
            theta_after_decay = theta_after_decay -
                                (theta_after_decay >> THETA_DECAY_SHIFT);
    end

    always @(posedge clock) begin
        if (reset) begin
            membrane_potential_register <= {MEMBRANE_BIT_WIDTH{1'b0}};
            adaptive_threshold_register <= {THRESHOLD_BIT_WIDTH{1'b0}};
            refractory_counter_register <= {REFRACTORY_BIT_WIDTH{1'b0}};
            spike_output_register       <= 1'b0;
        end else begin
            // spike_output is always a single-cycle pulse
            spike_output_register <= 1'b0;

            // membrane_clear and lateral inhibition act even while the
            // cluster is frozen, so they are evaluated ahead of `enable`.
            if (membrane_clear) begin
                membrane_potential_register <= {MEMBRANE_BIT_WIDTH{1'b0}};
                refractory_counter_register <= {REFRACTORY_BIT_WIDTH{1'b0}};
            end else if (force_inhibit) begin
                // WTA lateral inhibition: wipe membrane, force refractory.
                membrane_potential_register <= {MEMBRANE_BIT_WIDTH{1'b0}};
                refractory_counter_register <= REFRACTORY_CYCLES[REFRACTORY_BIT_WIDTH-1:0];
            end else if (enable) begin

                // theta relaxes on every leak tick
                adaptive_threshold_register <= theta_after_decay[THRESHOLD_BIT_WIDTH-1:0];

                if (refractory_counter_register != 0) begin
                    refractory_counter_register <= refractory_counter_register - 1'b1;
                    membrane_potential_register <= {MEMBRANE_BIT_WIDTH{1'b0}};
                end else if (fires && fire_enable && fire_grant) begin
                    spike_output_register       <= 1'b1;
                    membrane_potential_register <= {MEMBRANE_BIT_WIDTH{1'b0}};
                    refractory_counter_register <= REFRACTORY_CYCLES[REFRACTORY_BIT_WIDTH-1:0];
                    if (adaptation_enable)
                        adaptive_threshold_register <=
                            theta_after_decay[THRESHOLD_BIT_WIDTH-1:0] +
                            THETA_INCREMENT[THRESHOLD_BIT_WIDTH-1:0];
                end else begin
                    // NOTE: when fires && !fire_enable the membrane is held
                    // above threshold, so the spike is DEFERRED until the
                    // cluster unfreezes rather than being lost. The cluster
                    // freeze must never block synaptic integration -- weight
                    // distribution happens *during* an STDP transaction.
                    membrane_potential_register <= membrane_after_leak[MEMBRANE_BIT_WIDTH-1:0];
                end
            end
        end
    end

endmodule
