//==============================================================================
// Project: Neuromorphic Processing System - FYP II
// Module: Simple Leaky Integrate-and-Fire (LIF) Neuron Model
// Description: Implements a simplified LIF neuron with spike detection,
//              threshold management, and temporal dynamics
// Author: On-chip-Online-Team
// Date: 2026-01-11
//==============================================================================

`timescale 1ps/1ps

// Note: The following are included during compilation at the top level
// `include "internal_neuron_accumulator.v"
// `include "internal_neuron_counter.v"

//==============================================================================
// MODULE DECLARATION
//==============================================================================

module simple_LIF_Neuron_Model (
    // Clock and Control Signals
    input wire clock,                    // System clock for synchronization
    input wire reset,                    // Asynchronous reset signal
    input wire enable,                   // Module enable control
    
    // Input/Output Spike Signals
    input wire input_spike_wire,         // Input spike event trigger
    output wire spike_output_wire        // Output spike generation signal
);

//==============================================================================
// INTERNAL SIGNAL DECLARATIONS
//==============================================================================

// Accumulator Control Signals
wire internal_neuron_accumulator_enable_wire;     // Enable signal for spike accumulator
wire internal_neuron_counter_enable_wire;         // Enable signal for timing counter
wire internal_neuron_counter_reset_wire;          // Reset signal for timing counter
wire internal_neuron_accumulator_decay_wire;      // Trigger decay operation on accumulator
wire [31:0] internal_neuron_accumulator_decay_value_wire;  // Decay amount for membrane potential

// Data Signals from Sub-modules
wire [31:0] accumulator_spike_count_wire;         // Current spike accumulation count
wire [31:0] internal_count_value_wire;            // Current elapsed time count


//==============================================================================
// NEURON CUSTOMIZATION PARAMETERS
//==============================================================================
// These registers define the behavior and characteristics of the LIF neuron.
// Adjust these values to tune neuron response and learning dynamics.

// Temporal Parameters
reg [31:0] spike_time_width_reg = 32'h0003C;     // Time window for spike detection (60 counts)
reg [31:0] settling_time_reg = 32'h00004;        // Recovery period after spike event (4 counts)

// Threshold Management Parameters
reg [31:0] threshold_reg = 32'h000A;              // Initial spike threshold (10 spikes)
reg [31:0] spike_threshold_accumulation_value_reg = 32'h0002;  // Threshold increase per spike (2 units)

// Decay Parameters
reg [31:0] decay_value_reg = 32'h0001;            // Membrane potential decay per time step (1 unit)








//State managing Registers

//State variable - output spike
reg spike_output_reg = 1'b0;
//State variable to indicate if within spike event
reg within_spike_event_reg = 1'b0;
// State to manage the settling of the neuron after time window
reg within_settling_time_reg = 1'b0;
// Enable counter for spike time window
reg internal_neuron_counter_enable_reg = 1'b0;
//Spike Threshhold increasing value reg
reg [31:0] spike_threshold_increase_value_reg = 32'h0000; // example value
//Decay accumulator enable reg
reg decay_accumulator_enable_reg = 1'b0;

//Register for resetting internal counter
reg internal_neuron_counter_reset_reg = 1'b0;
// Accumulation after spike register
reg accumulate_after_spike = 1'b0;






/****************Instantiating internal modules****************/

// Spike Accumulator Module
// Purpose: Accumulates incoming spikes and tracks membrane potential
// Features: Integrates spikes, applies decay, triggers on threshold crossing
Internal_neuron_accumulator neuron_accumulator_instance_01(
    .enable(internal_neuron_accumulator_enable_wire),
    .reset(reset),
    .spike_input(input_spike_wire),
    .spike_count(accumulator_spike_count_wire),
    .reset_due_to_spike(spike_output_wire),
    .decay_accumulator(internal_neuron_accumulator_decay_wire),
    .decay_value(internal_neuron_accumulator_decay_value_wire)
);

// Timing Counter Module
// Purpose: Tracks elapsed time within spike detection window
// Features: Counts clock cycles, enables temporal state management
Internal_neuron_counter neuron_counter_instance_01(
    .clock(clock),
    .reset(internal_neuron_counter_reset_wire),
    .enable(internal_neuron_counter_enable_wire),
    .count(internal_count_value_wire)
);


//==============================================================================
// COMBINATIONAL LOGIC - SIGNAL ASSIGNMENTS
//==============================================================================
// These continuous assignments route control signals and data between
// the neuron state machine and internal functional modules

// Accumulator Control Signals
assign internal_neuron_accumulator_enable_wire = within_spike_event_reg;     // Enable accumulation during spike window
assign internal_neuron_accumulator_decay_wire = decay_accumulator_enable_reg;  // Enable decay during recovery
assign internal_neuron_accumulator_decay_value_wire = decay_value_reg;        // Apply configured decay rate

// Counter Control Signals
assign internal_neuron_counter_enable_wire = within_spike_event_reg;          // Enable counter during spike window
assign internal_neuron_counter_reset_wire = internal_neuron_counter_reset_reg; // Reset counter when needed

// Output Signal Routing
assign spike_output_wire = spike_output_reg;                                  // Route internal spike to output port



//==============================================================================
// SEQUENTIAL LOGIC - STATE MACHINE
//==============================================================================
// This always block implements the core LIF neuron state machine with
// four distinct operational states:
//   1. IDLE: Waiting for initial spike
//   2. ACCUMULATION: Collecting spikes within time window
//   3. THRESHOLD_CHECK: Monitoring threshold and spike generation
//   4. SETTLING: Recovery period with membrane decay
//
// Triggering events: Clock edges, Reset signal, Input spike events

always @(posedge clock or posedge reset or posedge input_spike_wire) begin

    // ========================================================================
    // RESET CONDITION - Initialize all state variables
    // ========================================================================
    if (reset) begin
        spike_output_reg <= 1'b0;
        within_spike_event_reg <= 1'b0;
        within_settling_time_reg <= 1'b0;
        threshold_reg <= 32'h000A;                      // Return to initial threshold
        spike_threshold_increase_value_reg <= 32'h0000; // Clear learning value
        internal_neuron_counter_reset_reg <= 1'b1;      // Reset timing counter
        accumulate_after_spike <= 1'b0;
    end
    
    // ========================================================================
    // OPERATIONAL LOGIC - Execute only when neuron is enabled
    // ========================================================================
    else if (enable) begin

        // ====================================================================
        // STATE 0: IDLE - No spike event active
        // ====================================================================
        // Transition condition: Waiting for initial spike event
        // Action: Initialize spike detection window
        // ====================================================================
        if (within_spike_event_reg == 1'b0 && within_settling_time_reg == 1'b0) begin
            within_spike_event_reg <= 1'b1;             // Activate spike detection window
            internal_neuron_counter_reset_reg <= 1'b0;  // Enable counter for time tracking
        end


        // ====================================================================
        // STATE 1: ACCUMULATION - Monitoring for threshold crossing
        // ====================================================================
        // Transition condition: Spike count reaches threshold, within time window
        // Action: Generate output spike and update adaptive threshold
        // ====================================================================
        if ((accumulator_spike_count_wire >= threshold_reg) && 
            (within_settling_time_reg == 1'b0) && 
            (within_spike_event_reg == 1'b1)) begin
            
            // Output spike generation
            spike_output_reg <= 1'b1;
            
            // Adaptive threshold: Increase threshold to prevent redundant firing
            // This implements Hebbian learning - neurons that just fired become
            // less responsive to prevent continuous firing
            spike_threshold_increase_value_reg <= spike_threshold_increase_value_reg + 
                                                   spike_threshold_accumulation_value_reg;
            threshold_reg <= threshold_reg + spike_threshold_increase_value_reg;
            
            // Note: spike_output_reg connects to accumulator's reset signal,
            // automatically resetting membrane potential after spike generation
            
            // Feature control: Define post-spike accumulation behavior
            if (accumulate_after_spike) begin
                // Allow continued accumulation after spike (TBD implementation)
                // This enables burst firing behavior
            end else begin
                // Prevent accumulation after spike (TBD implementation)
                // This enables single-spike-per-window behavior
            end
        end
        
        // ================================================================
        // STATE 2: TIME WINDOW EXPIRATION - Transition to settling phase
        // ================================================================
        // Transition condition: Elapsed time exceeds spike detection window
        // Action: Close spike accumulation window and initiate recovery
        // ================================================================
        if ((internal_count_value_wire >= spike_time_width_reg) && 
            (within_spike_event_reg == 1'b1) && 
            (within_settling_time_reg == 1'b0)) begin
            
            within_spike_event_reg <= 1'b0;  // Disable spike accumulation
            
            // Reset output spike signal if it was generated during window
            if (spike_output_reg == 1'b1) begin
                spike_output_reg <= 1'b0;
            end
            
            internal_neuron_counter_reset_reg <= 1'b1; // Prepare counter reset
            within_settling_time_reg <= 1'b1;          // Enter settling phase
        end


        // ================================================================
        // STATE 3: SETTLING PHASE - Membrane decay and recovery
        // ================================================================
        // Transition condition: Settling period expires
        // Action: Enable decay of membrane potential, return to IDLE
        // ================================================================
        if ((internal_count_value_wire >= (spike_time_width_reg + settling_time_reg)) && 
            (within_settling_time_reg == 1'b1)) begin
            
            within_settling_time_reg <= 1'b0;         // Exit settling phase
            decay_accumulator_enable_reg <= 1'b1;     // Activate membrane decay
            internal_neuron_counter_reset_reg <= 1'b0; // Enable counter if needed
        end

    end
end

endmodule


// ============================================================================
// MODULE END
// ============================================================================