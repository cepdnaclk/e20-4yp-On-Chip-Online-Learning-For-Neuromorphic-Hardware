# Izhikevich Neuron Module

Implementation of the Izhikevich neuron model - a more biologically realistic neuron capable of reproducing various firing patterns.

## Overview

The Izhikevich model can reproduce spiking and bursting behavior of known types of cortical neurons using a simple two-dimensional system of ordinary differential equations.

## Features

- Multiple firing pattern support (regular spiking, chattering, bursting, etc.)
- Efficient hardware implementation
- Configurable parameters for different neuron types
- Better biological realism than LIF

## Neuron Equation

```
dv/dt = 0.04v² + 5v + 140 - u + I
du/dt = a(bv - u)

if v ≥ 30mV:
    v ← c
    u ← u + d
```

## Parameters

- **a**: Time scale of recovery variable
- **b**: Sensitivity of recovery variable to membrane potential
- **c**: After-spike reset value of membrane potential
- **d**: After-spike reset of recovery variable

## Status

This module is planned for future implementation to support more complex neuronal dynamics.
