# Crossbar Interconnect Module

Synaptic crossbar logic and routing infrastructure for spike communication between neuron layers.

## Overview

The crossbar module implements the interconnection network that routes spikes from source neurons to destination neurons through weighted synaptic connections.

## Features

- Configurable crossbar dimensions (N×M)
- Weight matrix storage and access
- Parallel spike routing
- Support for sparse connectivity patterns
- Low-latency spike delivery

## Architecture

```
Input Neurons (N) → [Crossbar Matrix] → Output Neurons (M)
                      [Weight Memory]
```

## Connectivity Options

1. **Full Crossbar**: Every input connected to every output
2. **Sparse Crossbar**: Selected connections only (memory efficient)
3. **Structured Patterns**: Regular connectivity patterns (e.g., convolutional)

## Parameters

- `N_INPUTS`: Number of input neurons
- `N_OUTPUTS`: Number of output neurons
- `WEIGHT_WIDTH`: Synaptic weight precision
- `SPARSE_MODE`: Enable sparse connectivity

## Memory Organization

Weights can be stored in:
- Register array (fast, area-intensive)
- SRAM (balanced)
- External memory (large networks)

## Status

This module is planned for implementation to support multi-layer neuromorphic networks.

## Interface

- **Input**: Spike events from source layer
- **Output**: Weighted spike events to destination layer
- **Config**: Weight update interface for learning
