
### Parameters

- **DATA_WIDTH**: Bit-width for weights and traces (default 16 bits).
- **ADDR_WIDTH**: Bit-width for synapse addressing (default 10 bits, so 1024 synapses).
- **DECAY_SHIFT**: Controls the rate of exponential decay for traces (higher = slower decay).
- **LTP_WINDOW, LTD_WINDOW**: Not directly used in this code, but typically set the potentiation/depression window.
- **MAX_WEIGHT**: Maximum allowed value for a synaptic weight.

### Inputs

- **clk**: Clock signal for synchronous logic.
- **rst_n**: Active-low reset signal.
- **post_fire**: Indicates the neuron itself has fired (triggers LTP).
- **pre_spike_in**: Indicates a specific input synapse has fired (triggers LTD).
- **syn_addr**: Address of the synapse being processed (used for memory access).
- **weight_in**: Current weight value read from RAM for the addressed synapse.
- **pre_trace_in**: Current pre-synaptic trace value for the addressed synapse.

### Outputs

- **weight_out**: Updated weight value to be written back to RAM.
- **weight_we**: Write enable for weight memory (high when weight_out should be written).
- **pre_trace_out**: Updated pre-synaptic trace value to be written back.
- **trace_we**: Write enable for trace memory (high when pre_trace_out should be written).

### Internal Registers

- **post_trace**: Register holding the post-synaptic trace for the neuron itself. This value decays over time and is set to max when the neuron fires.

---

## Internal Functionality

### Post-Synaptic Trace Logic

- **post_trace** is updated every clock cycle:
  - On reset: set to 0.
  - On neuron spike (**post_fire**): set to max value.
  - Otherwise: decays exponentially (`post_trace = post_trace - (post_trace >> DECAY_SHIFT)`).

### STDP Update Logic (always @(*))

- **weight_out**, **weight_we**, **pre_trace_out**, **trace_we** are combinatorially determined based on input events.

#### Case A: Pre-Synaptic Spike (**pre_spike_in**)

- **pre_trace_out**: Set to max (indicating a recent spike).
- **trace_we**: Set high to write the updated trace.
- **weight_out**: Decreased by a value proportional to **post_trace** (depression/LTD). If result would be negative, saturate at 0.
- **weight_we**: Set high to write the updated weight.

#### Case B: Post-Synaptic Spike (**post_fire**)

- **pre_trace_out**: Decayed (passive decay step).
- **trace_we**: Set high to write the updated trace.
- **weight_out**: Increased by a value proportional to **pre_trace_in** (potentiation/LTP). If result would exceed **MAX_WEIGHT**, saturate at **MAX_WEIGHT**.
- **weight_we**: Set high to write the updated weight.

---

## Summary Table

| Name           | Type         | Usage/Functionality                                                                 |
|----------------|--------------|-------------------------------------------------------------------------------------|
| clk            | input wire   | Clock for synchronous logic                                                         |
| rst_n          | input wire   | Active-low reset                                                                    |
| post_fire      | input wire   | Indicates neuron fired (LTP event)                                                  |
| pre_spike_in   | input wire   | Indicates input synapse fired (LTD event)                                           |
| syn_addr       | input wire   | Address of synapse being processed                                                  |
| weight_in      | input wire   | Current synaptic weight from memory                                                 |
| weight_out     | output reg   | Updated synaptic weight to write back                                               |
| weight_we      | output reg   | Write enable for weight memory                                                      |
| pre_trace_in   | input wire   | Current pre-synaptic trace from memory                                              |
| pre_trace_out  | output reg   | Updated pre-synaptic trace to write back                                            |
| trace_we       | output reg   | Write enable for trace memory                                                       |
| post_trace     | reg          | Neuron's own post-synaptic trace (decays, spikes on neuron fire)                    |
