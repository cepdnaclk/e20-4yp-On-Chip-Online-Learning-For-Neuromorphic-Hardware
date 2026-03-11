# NOMAD-EONS: C++ Implementation Plan

## 1. Overview

**NOMAD-EONS** (Neuromorphic On-chip Modular Architecture with Distributed Evolutionary Optimization for Neuromorphic Systems) is a hardware-centric C++ implementation of the EONS framework. The goal is to produce a C++ model that is structurally and behaviourally close to a synthesizable Verilog design, enabling:

- Rapid prototyping of evolutionary neuromorphic architectures.
- Bit-accurate functional verification before RTL implementation.
- Exploration of topology, neuron parameters, and evolutionary strategies.

---

## 2. Design Decisions Summary

| Decision | Choice | Rationale |
|---|---|---|
| Arithmetic | Custom `FixedPoint<W,I>` class | Match hardware bit-widths exactly; avoid floating-point divergence from RTL |
| Simulation style | **Event-driven** | Faster than cycle-accurate; sufficient for functional verification |
| Inter-module communication | **Wire / Signal** abstraction | Mirrors Verilog `wire`/`reg`; makes C++ ↔ Verilog correspondence obvious |
| Evolutionary engine | **Hardware module** (not software wrapper) | Entire system is synthesizable; evolution runs on-chip |
| Build system | **CMake** | Cross-platform, widely supported, integrates with testing frameworks |

---

## 3. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Simulation Kernel                       │
│              (Event Scheduler / Signal Graph)               │
├──────────────┬──────────────────────┬───────────────────────┤
│              │                      │                       │
│  ┌───────────▼───────────┐  ┌──────▼──────────────┐  ┌─────▼──────────────┐
│  │   Neuromorphic Core   │  │  Evolutionary Unit  │  │  Environment I/F   │
│  │  ┌───────┐ ┌────────┐ │  │  ┌──────┐ ┌──────┐ │  │  ┌──────┐ ┌─────┐ │
│  │  │Neurons│ │  NOC   │ │  │  │Select│ │Mutate│ │  │  │Sensor│ │Actr │ │
│  │  └───┬───┘ └───┬────┘ │  │  └──┬───┘ └──┬───┘ │  │  └──┬───┘ └──┬──┘ │
│  │  ┌───▼─────────▼────┐ │  │  ┌──▼────────▼───┐ │  │     │        │    │
│  │  │ Memory Clusters  │ │  │  │Genotype Memory│ │  │     │        │    │
│  │  └──────────────────┘ │  │  └───────────────┘ │  │     │        │    │
│  └───────────────────────┘  └────────────────────┘  └─────────────────────┘
│                                                                             │
│              Signals / Wires (Event-Driven Propagation)                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Layers

1. **Simulation Kernel** – Lightweight event scheduler. When a `Signal` is written, all connected `Module` sensitivity lists are triggered.
2. **Neuromorphic Core** – Contains Neurons, NOC Routers, and Memory Clusters.
3. **Evolutionary Unit (EU)** – A hardware state machine that manages the population of SNN genotypes and drives selection, crossover, and mutation.
4. **Environment Interface** – Feeds stimuli to input neurons and collects output spikes for fitness evaluation.

---

## 4. Proposed Directory Structure

```
NOMAD_EONS/
├── CMakeLists.txt
├── README.md
├── implementation_plan.md
│
├── include/
│   ├── core/
│   │   ├── fixed_point.h          # FixedPoint<TotalBits, IntBits> template
│   │   ├── signal.h               # Signal<T> wire abstraction
│   │   └── module.h               # Module base class
│   │
│   ├── neuro/
│   │   ├── neuron_lif.h           # Leaky Integrate-and-Fire neuron
│   │   ├── synapse.h              # Synapse with weight and delay
│   │   └── spike_packet.h         # Packet/Flit definition for NOC
│   │
│   ├── noc/
│   │   ├── router.h               # 5-port NOC router
│   │   ├── arbiter.h              # Round-robin / priority arbiter
│   │   └── noc_mesh.h             # Mesh topology builder
│   │
│   ├── memory/
│   │   └── memory_cluster.h       # RAM block with address/data signals
│   │
│   ├── evo/
│   │   ├── genotype.h             # Genome encoding for an SNN
│   │   ├── tournament_selector.h  # Tournament selection logic
│   │   ├── crossover.h            # Child generator / crossover
│   │   ├── mutator.h              # Random mutation engine
│   │   ├── prng.h                 # LFSR / Xorshift PRNG
│   │   └── evolution_unit.h       # Top-level EU state machine
│   │
│   └── env/
│       └── environment.h          # Stimulus / fitness interface
│
├── src/
│   ├── core/
│   │   ├── fixed_point.cpp
│   │   ├── signal.cpp
│   │   └── module.cpp
│   │
│   ├── neuro/
│   │   ├── neuron_lif.cpp
│   │   └── synapse.cpp
│   │
│   ├── noc/
│   │   ├── router.cpp
│   │   ├── arbiter.cpp
│   │   └── noc_mesh.cpp
│   │
│   ├── memory/
│   │   └── memory_cluster.cpp
│   │
│   ├── evo/
│   │   ├── genotype.cpp
│   │   ├── tournament_selector.cpp
│   │   ├── crossover.cpp
│   │   ├── mutator.cpp
│   │   ├── prng.cpp
│   │   └── evolution_unit.cpp
│   │
│   └── env/
│       └── environment.cpp
│
├── tests/
│   ├── test_fixed_point.cpp
│   ├── test_signal.cpp
│   ├── test_neuron.cpp
│   ├── test_router.cpp
│   ├── test_prng.cpp
│   └── test_evolution.cpp
│
└── sim/
    └── main.cpp                   # Top-level simulation entry point
```

---

## 5. Component Details

### 5.1 Foundation – Hardware Abstraction (`core/`)

#### `FixedPoint<TotalBits, IntBits>`
- Template class where `TotalBits` is the total word width, `IntBits` is the integer part (rest is fractional).
- Overloads `+`, `-`, `*`, `/`, comparison, and shift operators.
- Internally stores value as `int32_t` or `int64_t` (depending on width).
- Provides `to_float()` for debug/logging only.

#### `Signal<T>`
- Holds a value of type `T` (e.g., `FixedPoint<16,8>`, `bool`, `SpikePacket`).
- On `write(val)`: if value changed, pushes an event to the kernel's event queue.
- Modules register sensitivity to signals (like Verilog `always @(posedge clk)`).

#### `Module`
- Base class with `virtual void process() = 0`.
- Registers input/output `Signal` ports.
- `process()` is called by the kernel when a sensitive signal changes.

### 5.2 Neuromorphic Core (`neuro/`, `noc/`, `memory/`)

#### Neuron (LIF)
- **Inputs**: `Signal<SpikePacket> spike_in`, `Signal<bool> clk`
- **Outputs**: `Signal<SpikePacket> spike_out`
- **Parameters** (from Memory Cluster): threshold (`FixedPoint`), leak rate, refractory period.
- **Behaviour**: Accumulates weighted input. Leaks each clock edge. Fires when membrane ≥ threshold.

#### NOC Router (5-port Mesh)
- Ports: North, South, East, West, Local.
- XY routing algorithm.
- Input/output buffers (FIFO depth configurable).
- Arbiter resolves contention using round-robin.

#### Memory Cluster
- Modeled as addressable RAM with `Signal<addr>` and `Signal<data>` ports.
- Stores: synaptic weights, neuron parameters, and connectivity (topology map).
- Read latency is 1 event cycle.

### 5.3 Evolutionary Unit (`evo/`)

The EU is a **hardware state machine** with the following states:

```
  ┌──────┐    timeout    ┌──────────┐   done    ┌────────┐
  │ IDLE ├──────────────►│ EVALUATE ├──────────►│ SELECT │
  └──────┘               └──────────┘           └───┬────┘
       ▲                                            │
       │    ┌─────────────┐   done    ┌─────────┐   │
       └────┤ RECONFIGURE │◄──────────┤  BREED  │◄──┘
            └─────────────┘           └─────────┘
```

| State | Action |
|---|---|
| **IDLE** | SNN is running the task. Collect fitness via reward signal port. |
| **EVALUATE** | Compute fitness scores for all individuals. |
| **SELECT** | Run tournament selection on fitness array. Pick parents. |
| **BREED** | Apply crossover and mutation to produce new genomes. |
| **RECONFIGURE** | Write new weights/connections to the Neuromorphic Core via Configuration Bus. |

#### Sub-modules
- **Tournament Selector**: Compares `k` random individuals; selects the fittest.
- **Crossover**: Single-point or uniform crossover on the genome bitstream.
- **Mutator**: Bit-flip mutations on weights/connections with configurable probability.
- **PRNG**: 32-bit LFSR or Xorshift generator. Deterministic seed for reproducibility.

### 5.4 Environment Interface (`env/`)

- Translates external task data (e.g., XOR truth table, sensor readings) into spike trains on input neurons.
- Reads output neuron spikes and computes a fitness/reward value.
- Feeds reward signal into the EU's fitness tracker port.

---

## 6. Implementation Phases

### Phase 1 – Foundation (Weeks 1–2)
- [x] Set up CMake project.
- [x] Implement `FixedPoint`, `Signal`, `Module`, and the Event Scheduler.
- [x] Write unit tests for `FixedPoint` arithmetic and `Signal` propagation.

### Phase 2 – Neuromorphic Core (Weeks 3–4)
- [x] Implement `NeuronLIF`, `Synapse`, `SpikePacket`.
- [x] Implement `MemoryCluster`.
- [x] Implement `Router`, `Arbiter`, `NocMesh`.
- [x] Test: Single neuron fires when input exceeds threshold.
- [x] Test: Two neurons communicate through a 2×2 NOC.

### Phase 3 – Evolutionary Unit (Weeks 5–6)
- [x] Implement `Genotype` encoding.
- [x] Implement `PRNG`, `Mutator`, `Crossover`, `TournamentSelector`.
- [x] Implement `EvolutionUnit` state machine.
- [x] Test: EU completes one full cycle (IDLE → ... → RECONFIGURE → IDLE).

### Phase 4 – Integration & Benchmarking (Weeks 7–8)
- [x] Implement `Environment` for a simple task (e.g., XOR classification).
- [x] Wire the full system: Environment ↔ Core ↔ EU.
- [x] Run evolution for N generations and verify fitness improvement.
- [ ] Profile performance and optimize hot paths.

---

## 7. Verification Plan

### Automated Tests (GoogleTest / Catch2)
| Test | What it verifies |
|---|---|
| `test_fixed_point` | Arithmetic accuracy, overflow/underflow clamping, bit-width correctness |
| `test_signal` | Event propagation, fan-out to multiple modules |
| `test_neuron` | LIF membrane dynamics, spike generation, refractory period |
| `test_router` | XY routing correctness, buffer overflow handling |
| `test_prng` | Period length, distribution uniformity |
| `test_evolution` | Full EU cycle produces valid child genomes |

### Manual / Visual Verification
- **Spike Raster Plots**: Log spike times, visualize with Python/Matplotlib.
- **Fitness Curves**: Plot fitness vs. generation to confirm convergence.
- **Signal Traces**: Optional VCD dump for waveform viewing in GTKWave.

---

## 8. Dependencies

| Dependency | Purpose | Required? |
|---|---|---|
| C++17 compiler | Language standard (templates, `<optional>`, structured bindings) | Yes |
| CMake ≥ 3.16 | Build system | Yes |
| GoogleTest | Unit testing | Recommended |
| Matplotlib (Python) | Plotting fitness / spike rasters | Optional |
| GTKWave | Viewing VCD waveforms | Optional |
