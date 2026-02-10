# AER RX/TX Module

Address Event Representation (AER) Interface for efficient spike communication in neuromorphic systems.

## Overview

AER is an asynchronous communication protocol that transmits spike events as address-event pairs. This module implements the transmitter and receiver logic for spike routing between neurons.

## Directory Structure

- **rtl/**: RTL implementation
  - `aer_decoder.v`: Decodes incoming spike addresses to neuron IDs
  - `spike_buffer.v`: FIFO buffer for spike event queuing
- **tb/**: Testbenches
  - `tb_aer_rx_tx.v`: AER interface testbench

## AER Protocol

Each spike event is represented as:
```
{address, timestamp}
```

Where:
- **address**: Target neuron or synapse identifier
- **timestamp**: Optional timing information

## Features

- Asynchronous handshake protocol
- Low-power event-driven communication
- Scalable to large neuron arrays
- FIFO buffering for spike bursts
- Address decoding and routing

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

## Interface Signals

- `spike_valid`: Spike event ready
- `spike_address`: Target neuron address
- `spike_ready`: Receiver ready for next spike
- `spike_ack`: Acknowledgment signal

## Parameters

- `ADDR_WIDTH`: Address bus width
- `FIFO_DEPTH`: Spike buffer depth
- `TIMESTAMP_WIDTH`: Timestamp precision
