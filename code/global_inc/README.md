# Global Include Directory

This directory contains system-wide parameters, macros, and definitions used across the entire neuromorphic hardware project.

## Files

- **neuro_defines.vh**: Verilog header file containing global macros and parameters
  - `SPIKE_WIDTH`: Bit-width for spike representation
  - `TIME_STEP`: Time discretization parameter
  - `NUM_NEURONS`: Total number of neurons in the system
  - Other system-level constants

- **aer_pkg.sv**: SystemVerilog package for Address Event Representation (AER)
  - AER packet structure definitions
  - Type definitions for spike events
  - Interface definitions for AER communication

## Usage

Include these files in your RTL modules using:
```verilog
`include "neuro_defines.vh"
```

For SystemVerilog modules:
```systemverilog
import aer_pkg::*;
```
