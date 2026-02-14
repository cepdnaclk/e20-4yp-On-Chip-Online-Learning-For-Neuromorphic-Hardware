//==============================================================================
// MODULE: Internal_neuron_counter
// AUTHOR: Hardware Neuroscience Research Lab
// DATE: Last Modified - February 2026
//
// PURPOSE:
// Implements a synchronous time-base counter for LIF neuron temporal dynamics.
// This module provides precise time-window tracking for neuron state management,
// enabling time-based operations such as integration periods, settling times,
// and temporal event scheduling.
//
// DESCRIPTION:
// The internal neuron counter serves as the fundamental timing element within
// the LIF neuron architecture. It provides a monotonically increasing time
// reference that drives:
//   1. TIME WINDOWS: Defines integration periods for spike accumulation
//   2. STATE TRANSITIONS: Triggers neuron state changes at precise intervals
//   3. SETTLING PERIODS: Manages post-spike recovery and stabilization phases
//   4. TEMPORAL DYNAMICS: Synchronizes membrane decay and threshold adaptation
//
// IMPLEMENTATION CHARACTERISTICS:
// - Synchronous operation: All state changes occur on clock edges
// - Asynchronous reset: Immediate return to initial state regardless of clock
// - Enable control: Allows temporal gating of counting operation
// - 32-bit resolution: Supports time windows up to 4.3 billion clock cycles
// - Overflow behavior: Wraps to 0 after reaching maximum count (2^32 - 1)
//
// USAGE IN LIF NEURON CONTEXT:
// This counter typically tracks elapsed time within a fixed integration window.
// When the count reaches a predefined threshold (e.g., spike_time_width_reg),
// the neuron performs operations such as:
//   - Evaluating accumulated spikes against firing threshold
//   - Resetting the accumulator for the next time window
//   - Applying membrane potential decay
//   - Updating adaptive threshold values
//
// HARDWARE CONSIDERATIONS:
// - Single-cycle increment: Minimal critical path (32-bit adder + register)
// - Low resource utilization: ~32 flip-flops + incrementer logic
// - Predictable timing: No combinational feedback loops
// - Synthesis-friendly: Standard synchronous design pattern
//==============================================================================

`timescale 1ps/1ps

module Internal_neuron_counter (
    //==========================================================================
    // PORT DECLARATIONS
    //==========================================================================
    
    // Clock and Reset
    input wire clock,           // System clock - drives synchronous counting
    input wire reset,           // Asynchronous reset - zeroes counter immediately
    
    // Control
    input wire enable,          // Enable signal - gates counter increment
    
    // Output
    output wire [31:0] count    // Current count value - elapsed time in clock cycles
);

//==============================================================================
// INTERNAL REGISTERS
//==============================================================================

// Primary State Register: TIME COUNTER
// Maintains the current elapsed time in clock cycles since last reset
// This register forms the temporal backbone of the neuron's time-based operations
//
// CHARACTERISTICS:
// - Width: 32 bits (supports counts from 0 to 4,294,967,295)
// - Initial Value: 0 (counter starts at zero on power-up/reset)
// - Update Rate: Increments by 1 each enabled clock cycle
// - Overflow: Wraps to 0 after reaching 0xFFFFFFFF (natural binary rollover)
//
// NEUROSCIENCE ANALOG:
// In biological neurons, this represents the internal "time keeper" that tracks
// the duration of integration periods and coordinates temporally-dependent
// processes like spike-timing-dependent plasticity (STDP) and refractory periods.
reg [31:0] count_reg = 32'b0;

//==============================================================================
// OUTPUT ASSIGNMENTS
//==============================================================================

// Direct connection of internal counter state to output port
// Provides continuous visibility of elapsed time for:
//   - Time window comparisons in parent neuron module
//   - State machine trigger conditions
//   - Temporal event scheduling
//   - Debug and monitoring interfaces
assign count = count_reg;

//==============================================================================
// SYNCHRONOUS COUNTER LOGIC
//==============================================================================
// Implements a standard synchronous counter with asynchronous reset
//
// DESIGN PATTERN: Dual-sensitivity always block
//   - Sensitive to: positive edge of clock (synchronous operation)
//   - Sensitive to: positive edge of reset (asynchronous reset)
//
// PRIORITY STRUCTURE:
//   1. RESET (highest priority) - overrides all other operations
//   2. ENABLE (conditional increment) - gates counting operation
//   3. HOLD STATE (default) - maintains current value when not enabled
//
// TIMING CHARACTERISTICS:
//   - Clock-to-output delay: Single flip-flop delay (Tco)
//   - Setup time: Must meet count_reg + 1 computation before clock edge
//   - Reset assertion: Asynchronous, takes effect immediately
//   - Reset recovery: Synchronous, counter resumes on next clock after reset release
//
// STATE TRANSITIONS:
//   RESET=1          : count_reg <= 0 (unconditional, immediate)
//   RESET=0, ENABLE=1: count_reg <= count_reg + 1 (increment)
//   RESET=0, ENABLE=0: count_reg <= count_reg (hold)
//==============================================================================

// Counter logic
always @(posedge clock or posedge reset) begin

    //--------------------------------------------------------------------------
    // PRIORITY LEVEL 1: ASYNCHRONOUS RESET
    //--------------------------------------------------------------------------
    // Reset condition takes absolute priority over all operations
    // Asynchronous behavior ensures immediate response regardless of clock state
    // Critical for reliable initialization and error recovery
    //
    // USE CASES:
    //   - System initialization on power-up
    //   - Time window boundary - restart integration period
    //   - Error recovery - restore known state
    //   - Settling period completion - re-initialize timing
    //--------------------------------------------------------------------------
    // Reset condition
    if (reset) begin

        // Reset count to zero
        count_reg <= 32'b0;

    //--------------------------------------------------------------------------
    // PRIORITY LEVEL 2: ENABLED INCREMENT
    //--------------------------------------------------------------------------
    // When enabled and not in reset, counter increments on each clock cycle
    // Non-blocking assignment (<=) ensures proper synchronous behavior
    //
    // OPERATION:
    //   count_reg(t+1) = count_reg(t) + 1
    //
    // ENABLE GATING USE CASES:
    //   - Pause timing during neuron inactive periods
    //   - Freeze counter for threshold comparison
    //   - Conditional time tracking based on neuron state
    //   - Power optimization by preventing unnecessary transitions
    //
    // INCREMENT BEHAVIOR:
    //   - Linear progression: 0, 1, 2, 3, ..., 2^32-1
    //   - Automatic overflow: 0xFFFFFFFF + 1 = 0x00000000
    //   - Single-cycle operation: completes in one clock period
    //--------------------------------------------------------------------------
    // Increment condition
    end else if (enable) begin

        // Increment count
        count_reg <= count_reg + 1;
    end
    //--------------------------------------------------------------------------
    // IMPLICIT PRIORITY LEVEL 3: HOLD STATE
    //--------------------------------------------------------------------------
    // When enable=0 and reset=0, no explicit action needed
    // Register inherently maintains its current value until next update
    // This "hold" behavior requires no code (implicit in Verilog semantics)
    //
    // BENEFITS:
    //   - Reduced switching activity (lower power consumption)
    //   - Stable timing reference when counter is paused
    //   - Simplifies control logic in parent module
    //--------------------------------------------------------------------------
end

//==============================================================================
// END OF MODULE
//==============================================================================

endmodule