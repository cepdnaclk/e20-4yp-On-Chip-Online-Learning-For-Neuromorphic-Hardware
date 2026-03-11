# NOMAD-EONS

**Neuromorphic On-chip Modular Architecture with Distributed Evolutionary Optimization for Neuromorphic Systems**

A hardware-centric C++ implementation of the EONS (Evolutionary Optimization of Neuromorphic Systems) framework, designed to closely mirror a synthesizable Verilog architecture.

---

## What is EONS?

EONS is an evolutionary algorithm that optimizes **Spiking Neural Networks (SNNs)** in hardware. Unlike traditional neuroevolution that runs in software, EONS treats the entire evolutionary loop — selection, crossover, mutation, and evaluation — as **hardware modules** operating on a chip alongside the neural network itself.

This C++ implementation serves as a **functional model** of that hardware, enabling:
- Architecture exploration before RTL design.
- Bit-accurate verification of neuron dynamics and evolutionary operators.
- Fast prototyping of different network topologies, neuron parameters, and mutation strategies.

---

## Design Decisions

### 1. Custom Fixed-Point Arithmetic (not `float`/`double`)

**Why?** Hardware (FPGAs/ASICs) uses fixed-point math. Using C++ `float` would produce results that diverge from the eventual Verilog implementation due to different rounding and precision behavior.

**How?** We implement a `FixedPoint<TotalBits, IntBits>` template class:
- `TotalBits` — total number of bits in the word (e.g., 16).
- `IntBits` — bits allocated to the integer part (e.g., 8), leaving the rest for the fractional part.
- All arithmetic operators (`+`, `-`, `*`, `/`) are overloaded with proper saturation and truncation.

```cpp
// Example: 16-bit word, 8 integer bits, 8 fractional bits
FixedPoint<16, 8> weight = FixedPoint<16, 8>::from_float(0.75f);
FixedPoint<16, 8> input  = FixedPoint<16, 8>::from_float(1.25f);
auto result = weight * input;  // bit-accurate multiplication
```

**Trade-off:** Slightly more complex code, but results are directly comparable to Verilog simulation.

---

### 2. Event-Driven Simulation (not Cycle-Accurate)

**Why?** A strict cycle-by-cycle simulator (like SystemC's `sc_signal`) would be the most accurate but is significantly slower. For our purposes — functional verification and architecture exploration — event-driven simulation provides the right balance of **speed** and **accuracy**.

**How?** Each module registers sensitivity to specific `Signal<T>` wires. When a signal value changes, only the affected modules are re-evaluated. Modules that see no input change are **not** simulated, saving computation.

**Trade-off:** We lose precise clock-edge timing information but gain 10–100× speed over cycle-accurate simulation. If exact timing matters for a specific test, we can fall back to stepping the clock manually.

---

### 3. Wire-Based Communication (not Function Calls)

**Why?** In Verilog, modules communicate through wires (`wire`, `reg`). To keep the C++ model structurally identical to the RTL, we use a `Signal<T>` class that mimics wire behavior.

**How?**
- Each `Signal` has a single driver and zero or more listeners.
- Writing to a signal queues an event in the simulation kernel.
- Connected modules are notified and execute their `process()` method.
- This directly mirrors a Verilog `always @(signal)` block.

```cpp
Signal<bool> spike_out;

// In Neuron module:
spike_out.write(true);  // triggers all connected downstream modules

// In downstream Router module:
void process() {
    if (spike_in.read()) {
        // route the spike packet
    }
}
```

**Trade-off:** More boilerplate than direct function calls, but the C++ code reads almost identically to Verilog, making RTL translation straightforward.

---

### 4. Evolution as a Hardware Module (not a Software Wrapper)

**Why?** In many neuroevolution frameworks, the evolutionary algorithm is software that calls into the neural network. In our system, **the evolutionary logic is itself a hardware module** that could be synthesized onto the same chip as the SNN. This is a core principle of EONS.

**How?** The **Evolutionary Unit (EU)** is a state machine module:

```
IDLE → EVALUATE → SELECT → BREED → RECONFIGURE → IDLE
```

- **IDLE**: The SNN runs the task; the EU passively collects reward/fitness signals.
- **EVALUATE**: Fitness scores are computed from accumulated rewards.
- **SELECT**: Tournament selection picks the fittest parents.
- **BREED**: Crossover and mutation produce new child genomes.
- **RECONFIGURE**: New weights and connections are written to the Neuromorphic Core's memory clusters via a configuration bus.

**Trade-off:** The EU must be designed within hardware constraints (no dynamic memory allocation, bounded loops, fixed population sizes). This is intentional — it ensures the C++ model is directly translatable to Verilog.

---

### 5. Component Architecture

The system is composed of **four major subsystems**, each built from hardware modules:

| Subsystem | Modules | Responsibility |
|---|---|---|
| **Core Infrastructure** | `FixedPoint`, `Signal`, `Module`, Event Scheduler | Simulation foundation |
| **Neuromorphic Core** | `NeuronLIF`, `Synapse`, `Router`, `Arbiter`, `MemoryCluster` | Running the SNN |
| **Evolutionary Unit** | `TournamentSelector`, `Crossover`, `Mutator`, `PRNG`, `EvolutionUnit` | Evolving the SNN |
| **Environment** | `Environment` | Task interface (input/output/fitness) |

---

### 6. Why Not SystemC?

SystemC is the industry-standard for hardware modeling in C++. We chose **not** to use it because:
- **Heavyweight**: SystemC requires installation of the OSCI library and has a steep learning curve.
- **Overhead**: Its full cycle-accurate kernel is more than we need for event-driven functional simulation.
- **Portability**: A custom lightweight framework is easier to build, understand, and deploy for an academic project.
- **Transparency**: Every line of our simulation infrastructure is visible and modifiable — important for a Final Year Project.

We borrow **concepts** from SystemC (signals, sensitivity lists, modules) but implement them minimally.

---

## Building

```bash
mkdir build && cd build
cmake ..
make -j$(nproc)
```

## Running Tests

```bash
cd build
ctest --output-on-failure
```

## Running a Simulation

```bash
./build/sim/nomad_eons [config.json]
```

---

## Project Structure

```
NOMAD_EONS/
├── include/           # Header files
│   ├── core/          #   FixedPoint, Signal, Module
│   ├── neuro/         #   Neuron, Synapse, SpikePacket
│   ├── noc/           #   Router, Arbiter, Mesh topology
│   ├── memory/        #   Memory Clusters
│   ├── evo/           #   Evolutionary Unit and sub-modules
│   └── env/           #   Environment interface
├── src/               # Implementation files (mirrors include/)
├── tests/             # Unit and integration tests
├── sim/               # Top-level simulation entry point
├── CMakeLists.txt     # Build configuration
├── README.md          # This file
└── implementation_plan.md  # Detailed plan with timeline
```

---

## References

- Schuman, C.D. et al., "Evolutionary Optimization for Neuromorphic Systems" (ORNL)
- Verilog-style modeling concepts from IEEE 1364 / SystemVerilog
