//==============================================================================
// MODULE: Internal_neuron_accumulator
// AUTHOR: Hardware Neuroscience Research Lab
// DATE: Last Modified - February 2026
//
// PURPOSE:
// Implements the membrane potential accumulator for a Leaky Integrate-and-Fire
// (LIF) neuron model. This module tracks the accumulated synaptic input by
// counting incoming spikes and modeling membrane potential dynamics including
// decay and refractory period behavior.
//
// DESCRIPTION:
// This accumulator represents the core computational element of the LIF neuron,
// implementing three key neurobiological mechanisms:
//   1. INTEGRATION: Accumulates incoming spike events (excitatory input)
//   2. LEAK: Models membrane potential decay through right-shift operations
//   3. REFRACTION: Implements refractory period by subtracting spike count
//
// The module uses an asynchronous sensitivity list to respond immediately to
// spike inputs, reset signals, and decay events - modeling the continuous-time
// behavior of biological neurons in a discrete digital system.
//
// OPERATION MODES:
// The module supports 8 operational states based on combinations of:
//   - spike_input (0/1): Presence of incoming spike
//   - reset_due_to_spike (0/1): Neuron fired, entering refractory period
//   - decay_accumulator (0/1): Time-based membrane potential leak
//
// SYNTHESIS NOTES:
// - Implements combinational logic with registered outputs
// - Asynchronous reset for immediate initialization
// - Arithmetic right-shift for efficient decay implementation
// - Underflow protection for refractory subtraction
//==============================================================================

`timescale 1ps/1ps

module Internal_neuron_accumulator
( 
    //==========================================================================
    // PORT DECLARATIONS
    //==========================================================================
    
    // Control Signals
    input wire enable,                  // Master enable - gates all accumulator operations
    input wire reset,                   // Asynchronous reset - initializes accumulator to default state
    
    // Data Input
    input wire spike_input,             // Incoming synaptic spike event (0=no spike, 1=spike detected)
    
    // Data Output
    output wire [31:0] spike_count,     // Current accumulated spike count (membrane potential proxy)
    
    // Neuron Control Signals
    input wire reset_due_to_spike,      // Neuron fired - initiate refractory period subtraction
    input wire decay_accumulator,       // Time-based decay trigger - models membrane leak
    input wire [31:0] decay_value       // Decay amount - number of bits to right-shift (2^n divisor)
);

//==============================================================================
// INTERNAL REGISTERS AND PARAMETERS
//==============================================================================

// Neurobiological Parameter: REFRACTORY PERIOD
// Defines the absolute refractory period duration in terms of spike count units
// After a neuron fires, this amount is subtracted from the accumulator to
// prevent immediate refiring, modeling the sodium channel inactivation period
// in biological neurons.
// Value: 0x000A (decimal 10) - represents ~10 time units of refractoriness
reg [31:0] refactory_period_count = 32'h000A; // example value

// Primary State Register: MEMBRANE POTENTIAL ACCUMULATOR
// Maintains the current integrated spike count, representing the neuron's
// membrane potential in discrete units. This register is the core state variable
// of the LIF neuron model.
// Initial: 0 (hyperpolarized/resting state)
// Range: 0 to 2^32-1 (with underflow protection)
reg [31:0] spike_count_reg = 32'b0;

// Legacy Parameter: DECAY VALUE REGISTER
// Historical implementation artifact - kept for reference
// Note: Current implementation uses decay_value input port directly
reg [31:0] decay_value_reg = 32'h0000; // example decay value

//==============================================================================
// OUTPUT ASSIGNMENTS
//==============================================================================

// Direct connection of internal accumulator state to output port
// Provides real-time visibility of membrane potential for threshold comparison
assign spike_count = spike_count_reg;

// Legacy Assignment (COMMENTED OUT)
// Original design considered internal decay value register
// Current design uses external decay_value input for better parameterization
//assign decay_value_reg = decay_value;

//==============================================================================
// LEGACY IMPLEMENTATION - ARCHIVED REFERENCE
//==============================================================================
// The following code blocks represent the initial modular implementation approach
// where each neuron operation (spike accumulation, reset, refractory, decay) was
// handled in separate always blocks with individual sensitivity lists.
//
// DEPRECATION REASON:
// This approach was replaced with the unified state machine below to better handle
// simultaneous events and ensure deterministic behavior when multiple control
// signals are asserted concurrently. The separate blocks could create race
// conditions and ambiguous priority when events occurred simultaneously.
//
// PRESERVED FOR:
// - Design evolution documentation
// - Understanding of implementation alternatives
// - Educational reference for initial design decisions
//==============================================================================

// // LEGACY BLOCK 1: Spike Input Accumulation
// // Original implementation: Increment on positive edge of spike_input
// // Limitation: Could not handle simultaneous decay or reset events
// always @(posedge spike_input) begin
    
//     if(enable) begin
//         spike_count_reg <= spike_count_reg + 1;
//     end

// end

// // LEGACY BLOCK 2: System Reset
// // Original implementation: Initialize accumulator on reset
// // Note: Initial value set to 1 (not 0) to prevent first spike from being missed
// // due to edge detection behavior in the original design
// always @(posedge reset) begin
//     // Set to 1 on reset - As with current implementation, first spike will be missed otherwise
//     spike_count_reg = 32'b0000_0000_0000_0000_0000_0000_0000_0001;
// end

// // LEGACY BLOCK 3: Refractory Period Implementation
// // Original implementation: Subtract refractory count when neuron fires
// // Issue: No underflow protection - could wrap to large positive values
// always @(posedge reset_due_to_spike) begin
//     //Reset due to spike - subtract refactory period
//     //Nedd to handle underflow
//     spike_count_reg = spike_count_reg - refactory_period_count;
// end

// // LEGACY BLOCK 4: Membrane Potential Decay
// // Original implementation: Fixed right-shift by 1 bit (divide by 2)
// // Limitation: Not parameterizable, always 50% decay
// always @(posedge decay_accumulator) begin
//     //Shift right to decay - simple decay implementation
//     spike_count_reg = spike_count_reg>>1; // example decay by half
// end

//==============================================================================
// CURRENT IMPLEMENTATION - UNIFIED STATE MACHINE
//==============================================================================
// This always block implements a comprehensive state machine that handles all
// possible combinations of input events. By using a single sensitivity list
// with all control signals, it ensures deterministic and predictable behavior
// when multiple events occur simultaneously.
//
// DESIGN RATIONALE:
// 1. Asynchronous sensitivity to spike_input, reset, reset_due_to_spike, decay
// 2. Explicit priority encoding for simultaneous events
// 3. Underflow protection for refractory subtraction
// 4. Parameterizable decay via decay_value input
//
// STATE SPACE: 8 operational modes (2^3 combinations)
// Priority: Reset > Enable > [spike_input, reset_due_to_spike, decay_accumulator]
//==============================================================================

always @(posedge spike_input or posedge reset or posedge reset_due_to_spike or posedge decay_accumulator) begin

    //--------------------------------------------------------------------------
    // PRIORITY LEVEL 1: SYSTEM RESET
    //--------------------------------------------------------------------------
    // Unconditional reset - highest priority
    // Initializes accumulator to 1 (not 0) to ensure proper edge detection
    // behavior for the first incoming spike after reset
    //--------------------------------------------------------------------------
    if (reset) begin
        // Set to 1 on reset - As with current implementation, first spike will be missed otherwise
        spike_count_reg = 32'b0000_0000_0000_0000_0000_0000_0000_0001;

    end

    //--------------------------------------------------------------------------
    // PRIORITY LEVEL 2: ENABLED OPERATION
    //--------------------------------------------------------------------------
    // All neuron operations are gated by the enable signal
    // When disabled, accumulator maintains current state (holds membrane potential)
    //--------------------------------------------------------------------------
    else if (enable) begin

        //======================================================================
        // OPERATIONAL STATE MACHINE - 8 MODES
        //======================================================================
        // The following conditions enumerate all possible combinations of the
        // three control signals: spike_input, reset_due_to_spike, decay_accumulator
        //
        // STATE ENCODING:
        // Binary: [spike_input][reset_due_to_spike][decay_accumulator]
        // Decimal states 0-7 represent all combinations (000 to 111)
        //
        // OPERATION PRIORITY (when multiple signals active):
        // 1. Decay accumulator (membrane leak)
        // 2. Reset due to spike (refractory subtraction)
        // 3. Spike input (excitatory integration)
        //======================================================================

        //----------------------------------------------------------------------
        // STATE 0: IDLE STATE [000]
        // spike_input = 0, reset_due_to_spike = 0, decay_accumulator = 0
        //----------------------------------------------------------------------
        // No action needed - accumulator maintains current value
        // Represents neuron in quiescent state with stable membrane potential
        // This condition requires no explicit code (implicit hold state)
        //----------------------------------------------------------------------

        //----------------------------------------------------------------------
        // STATE 1: PASSIVE DECAY [001]
        // spike_input = 0, reset_due_to_spike = 0, decay_accumulator = 1
        //----------------------------------------------------------------------
        // OPERATION: Membrane leak without synaptic input
        // Models passive decay of membrane potential over time
        // Implements leaky integrator characteristic of LIF neurons
        // Decay mechanism: Arithmetic right-shift by decay_value bits
        // Effect: Divides accumulator by 2^decay_value
        //----------------------------------------------------------------------
        // 02.spike_input = 0, reset_due_to_spike = 0, decay_accumulator = 1 --> No input spiike but accumulated value needs to be decayed
        if (spike_input == 0 && reset_due_to_spike  == 0 && decay_accumulator == 1) begin
            //Decay accumulator - shift right
            spike_count_reg <= spike_count_reg>>decay_value; // example decay by half
        end

        //----------------------------------------------------------------------
        // STATE 2: REFRACTORY PERIOD [010]
        // spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 0
        //----------------------------------------------------------------------
        // OPERATION: Post-spike refractory behavior
        // Implements absolute refractory period following action potential
        // Subtracts refactory_period_count from accumulator
        // UNDERFLOW PROTECTION: Clamps to 0 if subtraction would go negative
        // Edge case: Unlikely in normal operation, may occur due to FPGA
        //            timing variations or concurrent signal transitions
        //----------------------------------------------------------------------
        // 03.spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 0 --> No input spike but need to reset due to spike - But highly unlikely to happen, assume if there's any dalay in fpga cause to trigger this or this was implemented
        else if (spike_input == 0 && reset_due_to_spike  == 1 && decay_accumulator == 0) begin
            //Reset due to spike - subtract refactory period
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0; // Here it is set to zero since the neuron is in running state
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end
        end

        //----------------------------------------------------------------------
        // STATE 3: REFRACTORY WITH DECAY [011]
        // spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 1
        //----------------------------------------------------------------------
        // OPERATION: Combined refractory and leak dynamics
        // Edge case: Simultaneous refractory subtraction and decay
        // Sequence: (1) Refractory subtraction, (2) Decay operation
        // Biological analog: Refractory period with ongoing leak currents
        // Note: Rare condition, may occur during rapid firing patterns
        //----------------------------------------------------------------------
        // 04.spike_input = 0, reset_due_to_spike = 1, decay_accumulator = 1 --> No input spike but need to reset due to spike and decay accumulator - But highly unlikely to happen, assume if there's any dalay in fpga cause to trigger this or this was implemented
        else if (spike_input == 0 && reset_due_to_spike  == 1 && decay_accumulator == 1) begin
            //Reset due to spike - subtract refactory period
            // Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0; // Here it is set to zero since the neuron is in running state
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            //Decay accumulator - shift right
            spike_count_reg = spike_count_reg>>decay_value; // example decay by half

        end

        //----------------------------------------------------------------------
        // STATE 4: SPIKE INTEGRATION [100]
        // spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 0
        //----------------------------------------------------------------------
        // OPERATION: Normal excitatory synaptic integration
        // Primary neuron function - accumulates incoming spike
        // Increments spike_count_reg by 1 for each input spike
        // Models depolarization caused by excitatory postsynaptic potential (EPSP)
        //----------------------------------------------------------------------
        // 05.spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 0 --> Normal spike input
        else if(spike_input == 1 && reset_due_to_spike  == 0 && decay_accumulator == 0) begin
            spike_count_reg = spike_count_reg + 1;
        end

        //----------------------------------------------------------------------
        // STATE 5: INTEGRATION WITH DECAY [101]
        // spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 1
        //----------------------------------------------------------------------
        // OPERATION: Simultaneous leak and integration
        // Common scenario in sparse spiking networks
        // Sequence: (1) Decay current accumulator, (2) Add new spike
        // Models competition between leak currents and excitatory input
        // Net effect: spike_count = (spike_count >> decay_value) + 1
        //----------------------------------------------------------------------
        // 06.spike_input = 1, reset_due_to_spike = 0, decay_accumulator = 1 --> Spike input and decay accumulator
        else if (spike_input == 1 && reset_due_to_spike  == 0 && decay_accumulator == 1) begin
            // Initially decay accumulator
            spike_count_reg = spike_count_reg>>decay_value; // decay by half

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end
        

        //----------------------------------------------------------------------
        // STATE 6: INTEGRATION DURING REFRACTORY [110]
        // spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 0
        //----------------------------------------------------------------------
        // OPERATION: Input spike during refractory period
        // Sequence: (1) Refractory subtraction, (2) Integrate new spike
        // Biological interpretation: Input received during relative refractory
        //                           period - partially effective
        // Result: Net change = +1 - refactory_period_count
        //----------------------------------------------------------------------
        // 07.spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 0 --> Spike input and reset due to spike
        else if (spike_input == 1 && reset_due_to_spike  == 1 && decay_accumulator == 0) begin
            //Reset due to spike - subtract refactory period
            //Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0;
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end

        //----------------------------------------------------------------------
        // STATE 7: FULL DYNAMICS [111]
        // spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 1
        //----------------------------------------------------------------------
        // OPERATION: All three mechanisms active simultaneously
        // Complete neuron dynamics in single time step
        // Sequence: (1) Decay, (2) Refractory subtraction, (3) Integration
        // Rare but possible in high-frequency operation or timing edge cases
        // Comprehensive operation: ((count >> decay) - refractory) + 1
        //----------------------------------------------------------------------
        // 08.spike_input = 1, reset_due_to_spike = 1, decay_accumulator = 1 --> Spike input, reset due to spike and decay accumulator
        else if (spike_input == 1 && reset_due_to_spike  == 1 && decay_accumulator == 1) begin
            // Initially decay accumulator
            spike_count_reg = spike_count_reg>>decay_value; // decay by half

            //Reset due to spike - subtract refactory period
            //Handling underflow
            if(refactory_period_count >= spike_count_reg) begin
                spike_count_reg = 32'b0;
            end else begin
                spike_count_reg = spike_count_reg - refactory_period_count;
            end

            // Then add spike input
            spike_count_reg = spike_count_reg + 1;
        end
    end
end

endmodule
//==============================================================================
// END OF MODULE
//==============================================================================

