# LIF Standard Neuron Module

Leaky Integrate-and-Fire (LIF) neuron model implementation - the fundamental computational unit of the neuromorphic system.

## Overview

The LIF neuron integrates incoming spikes and fires when the membrane potential exceeds a threshold. The potential decays (leaks) over time, modeling biological neuron behavior.

## Directory Structure

- **rtl/**: RTL implementation
  - `lif_core.v`: Core membrane potential update logic
  - `leak_logic.v`: Decay/leakage mechanism
- **tb/**: Testbenches
  - `tb_lif_single.v`: Single neuron testbench
  - `spike_patterns.hex`: Test input patterns

## Features

- Configurable membrane time constant
- Adjustable firing threshold
- Refractory period support
- Reset mechanism after spike

## Building and Testing

### Simulate
```bash
make sim
```

### View Waveforms
```bash
make wave
```

### Clean
```bash
make clean
```

## Parameters

- `V_THRESH`: Firing threshold voltage
- `V_REST`: Resting membrane potential
- `TAU_MEM`: Membrane time constant
- `REFRAC_PERIOD`: Refractory period duration
