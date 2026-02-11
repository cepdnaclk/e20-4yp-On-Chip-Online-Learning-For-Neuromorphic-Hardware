# STDP Engine Module

Spike-Timing-Dependent Plasticity (STDP) learning engine - implements the core online learning mechanism for neuromorphic hardware.

## Overview

STDP is a biological learning rule that adjusts synaptic weights based on the relative timing of pre- and post-synaptic spikes. This module implements STDP in hardware for on-chip learning.

## Directory Structure

- **rtl/**: RTL implementation
  - `stdp_trace.v`: Trace update logic for pre/post-synaptic activity
  - `weight_update.v`: Potentiation and depression logic
- **tb/**: Testbenches
  - `tb_stdp_engine.v`: STDP engine testbench

## Learning Rule

**Potentiation (LTP)**: If pre-synaptic spike occurs before post-synaptic spike
```
Δw = A+ * exp(-Δt/τ+)
```

**Depression (LTD)**: If post-synaptic spike occurs before pre-synaptic spike
```
Δw = -A- * exp(-Δt/τ-)
```

## Features

- Hardware-efficient exponential approximation
- Configurable learning rates
- Trace-based implementation for efficiency
- Weight bounds and saturation handling

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

- `A_PLUS`: Potentiation amplitude
- `A_MINUS`: Depression amplitude
- `TAU_PLUS`: Potentiation time constant
- `TAU_MINUS`: Depression time constant
- `W_MIN`, `W_MAX`: Weight bounds
