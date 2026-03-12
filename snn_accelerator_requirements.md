# SNN Accelerator — Complete Design Requirements Specification

## Document Purpose

This document is the definitive implementation reference for an in-hardware Spiking Neural Network (SNN) accelerator implemented in Verilog. It is intended to be given directly to an AI coding agent to generate all Verilog source files. Every module, every port, every parameter, every behavioral rule, and every timing constraint is described herein. The agent must follow this document exactly and must not deviate from naming conventions, port directions, or module boundaries without explicit instruction.

---

## 1. Global Design Principles

### 1.1 Naming Conventions

- **Files**: All lowercase, words separated by underscores. File name must match the top-level module name declared inside it. Example: `trace_update_module.v` contains `module trace_update_module`.
- **Ports and signals**: Fully descriptive, no abbreviations. Use names that describe *purpose*, not structure. Examples: `weight_write_enable`, `trace_saturated_flag`, `decay_timer_current_value`, `spike_queue_full_flag`. Do NOT use names like `we`, `en`, `rst`, `d`, `q`.
- **Parameters**: ALL_CAPS_WITH_UNDERSCORES. Example: `NUM_NEURONS_PER_CLUSTER`.
- **Registers**: Suffix `_register` for explicitly registered values held across clock edges.
- **Wires**: No suffix needed if the name is already self-explanatory.
- **State machine states**: Prefix with module-abbreviation in caps. Example: in `stdp_controller.v`, states are `STDP_CTRL_IDLE`, `STDP_CTRL_FETCH_TRACES`, etc.
- **Active-low signals**: Suffix `_n`. Example: `reset_n`.
- **Bus indices**: When a bus selects among N items, use suffix `_index`. Example: `target_bank_index`.

### 1.2 Reset Behavior

All modules use synchronous active-high reset unless otherwise stated. On `reset` high, all registers return to defined initial values within one clock edge.

### 1.3 Handshaking Protocol

Wherever data flows between modules that may have variable latency, use the following two-signal handshake:
- `_valid`: asserted by the producer when the accompanying data is stable and meaningful.
- `_ready`: asserted by the consumer when it is able to accept data.
- A transaction occurs exactly when both `_valid` and `_ready` are high on the same rising clock edge.
- A `_busy` signal (single bit) is used where a module cannot accept new work: it is asserted when a module is processing and de-asserted when it can accept a new request.

### 1.4 Parameterization Philosophy

All size and behavioral values that could change between builds must be top-level Verilog parameters. Every module must pass relevant parameters down to its submodules via parameter overrides at instantiation. Parameters that affect bit widths must be consistently used with `$clog2` where address widths are derived.

### 1.5 Module Swappability

The following modules are explicitly designed to be swapped for upgraded implementations at a later stage. They must have stable, fixed port interfaces as defined in this document, and their internal implementation may change freely:
- `trace_increase_logic.v` — how a spike increases a trace value
- `weight_update_logic.v` — how LTP/LTD computes the new weight

Each swappable module file must include the following comment block immediately after the module declaration:

```verilog
// ============================================================
// SWAPPABLE MODULE — Do NOT modify the port interface.
// Internal implementation may be replaced freely.
// See SNN Accelerator Requirements Specification Section 1.5.
// ============================================================
```

---

## 2. System Parameters

These parameters are defined at the top level and propagated to all submodules.

| Parameter | Default | Description |
|---|---|---|
| `NUM_NEURONS_PER_CLUSTER` | `64` | Number of neurons in a single cluster. Must be a power of two. |
| `NEURON_ADDRESS_WIDTH` | `$clog2(NUM_NEURONS_PER_CLUSTER)` | Bit width of a neuron index address. |
| `NUM_WEIGHT_BANKS` | `NUM_NEURONS_PER_CLUSTER` | Number of banks in the banked weight memory. Always equals neuron count. |
| `WEIGHT_BANK_ADDRESS_WIDTH` | `NEURON_ADDRESS_WIDTH` | Address width inside each weight bank. |
| `WEIGHT_BIT_WIDTH` | `8` | Bit width of a single synaptic weight value. Weights are unsigned. |
| `TRACE_VALUE_BIT_WIDTH` | `8` | Bit width of the trace value field. |
| `DECAY_TIMER_BIT_WIDTH` | `12` | Bit width of the global decay timer counter. |
| `TRACE_SATURATION_THRESHOLD` | `256` | If the computed delta-t (in decay timer ticks) exceeds this value, the trace is treated as fully decayed to zero. Must be less than or equal to `2^(DECAY_TIMER_BIT_WIDTH - 1)` to ensure correct modular difference behavior. |
| `DECAY_SHIFT_LOG2` | `3` | Log base 2 of the number of decay timer ticks required for one right-shift of the trace. Determines the decay time constant. A value of 3 means that every 8 decay ticks, the trace value is halved. |
| `TRACE_INCREMENT_VALUE` | `32` | Amount added to trace on spike when in ADD_VALUE increase mode. |
| `NUM_TRACE_UPDATE_MODULES` | `NUM_NEURONS_PER_CLUSTER` | Number of parallel trace update modules available for concurrent trace operations. Can be set lower than neuron count to reduce area at the cost of throughput. |
| `SPIKE_QUEUE_DEPTH` | `NUM_NEURONS_PER_CLUSTER` | Depth of the simultaneous-spike FIFO queue. |
| `LTP_SHIFT_AMOUNT` | `2` | Right-shift applied to pre-synaptic trace when computing LTP weight change magnitude. |
| `LTD_SHIFT_AMOUNT` | `2` | Right-shift applied to post-synaptic trace when computing LTD weight change magnitude. |
| `INCREASE_MODE` | `0` | Selects trace increase behavior. 0 = SET_MAX (set to all-ones). 1 = ADD_VALUE (add TRACE_INCREMENT_VALUE with saturation). |

---

## 3. Memory Architecture

### 3.1 Conceptual Weight Matrix

The weight matrix is a logical 2D array of size `NUM_NEURONS_PER_CLUSTER × NUM_NEURONS_PER_CLUSTER`. Entry `W[post_neuron_index][pre_neuron_index]` represents the synaptic weight of the connection from pre-synaptic neuron `pre_neuron_index` to post-synaptic neuron `post_neuron_index`. This conceptual matrix is **never implemented directly** in hardware. It exists only to define the logical mapping used by the banked memory system.

### 3.2 Banked Weight Memory — Addressing Formula

The weight matrix is physically stored across `NUM_WEIGHT_BANKS` memory banks. The mapping from conceptual matrix coordinates to physical storage is:

```
Bank Index   B = (post_neuron_index + pre_neuron_index) mod NUM_WEIGHT_BANKS
Address A inside Bank B = post_neuron_index
```

Therefore, Bank `B` at Address `A` stores the weight:

```
W[A][(B - A + NUM_WEIGHT_BANKS) mod NUM_WEIGHT_BANKS]
```

That is: the weight at address `A` in bank `B` belongs to the connection whose post-synaptic neuron index is `A` and whose pre-synaptic neuron index is `(B - A) mod NUM_WEIGHT_BANKS`.

### 3.3 Row Access Pattern — STDP Weight Update

When post-synaptic neuron `i` fires and all its input synaptic weights must be read and updated simultaneously:

- Read address `i` from **all banks simultaneously** in a single clock cycle.
- Bank `B` returns the weight `W[i][(B - i) mod NUM_WEIGHT_BANKS]`.
- The pre-synaptic neuron index for the weight returned by Bank `B` is `(B - i + NUM_WEIGHT_BANKS) mod NUM_WEIGHT_BANKS`.
- Because `NUM_WEIGHT_BANKS` is a power of two, this modular subtraction is implemented as a plain `NEURON_ADDRESS_WIDTH`-bit subtraction with natural overflow — no explicit modulo circuit required.
- All banks return their values in the same clock cycle.

### 3.4 Column Access Pattern — Weight Distribution to Post-Synaptic Neurons

When pre-synaptic neuron `j` fires and its output weights must be distributed to post-synaptic neurons for membrane potential updates, the access is sequential (one weight per clock cycle):

- At step `k` (where `k` ranges from `0` to `NUM_NEURONS_PER_CLUSTER - 1`):
  - Read from Bank `(k + j) mod NUM_WEIGHT_BANKS` at Address `k`.
  - The weight returned is `W[k][j]`, belonging to post-synaptic neuron `k`.
- The bank index wraps naturally via `NEURON_ADDRESS_WIDTH`-bit addition overflow, requiring no explicit mod circuit.
- The starting bank at step `k=0` is bank `j`, since `j < NUM_WEIGHT_BANKS`.
- Total duration: `NUM_NEURONS_PER_CLUSTER` clock cycles to distribute all weights.

### 3.5 Trace Memory Entry Layout

Each neuron has one trace memory entry of 21 bits total:

```
Bit  [20]      : trace_saturated_flag
                 Value 1 means the trace has decayed fully to zero.
                 When this flag is set, the trace_value field is ignored
                 and all consumers must treat the effective trace as zero.

Bits [19:8]    : trace_stored_timestamp
                 The value of the global decay timer at the moment this
                 trace entry was last updated by a spike-triggered increase.
                 This timestamp is NOT updated during lazy decay reads.

Bits [7:0]     : trace_value
                 The raw 8-bit trace value as stored at the time of the
                 last spike-triggered increase. Actual effective value at
                 any given moment requires applying lazy decay using the
                 stored timestamp and current timer value.
```

Total trace memory size: `NUM_NEURONS_PER_CLUSTER × 21` bits, implemented as a single synchronous SRAM-style block.

On system reset, all entries must be initialized to `trace_saturated_flag=1`, `trace_stored_timestamp=0`, `trace_value=0`. The saturation flag being set on reset ensures all traces are treated as zero until a spike has occurred for each neuron.

---

## 4. Module Specifications

---

### 4.1 `global_decay_timer.v`

**Purpose:** Maintains the global decay tick counter used to timestamp trace updates and to compute lazy decay deltas. This counter only increments when a decay enable pulse is received. It is not a wall-clock cycle counter. It represents a logical "number of decay events that have occurred."

**Parameters:**
- `DECAY_TIMER_BIT_WIDTH`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `decay_enable_pulse` | 1 | When high for one clock cycle, the timer increments by one tick |
| output | `decay_timer_current_value` | `DECAY_TIMER_BIT_WIDTH` | Current timer value, registered. Wraps naturally at `2^DECAY_TIMER_BIT_WIDTH` |

**Behavior:**
- On `reset`: timer register set to 0.
- On rising clock edge when `decay_enable_pulse` is high: increment timer register by 1. Overflow wraps silently to zero. This wrap is handled safely by the modular subtraction in `trace_update_module.v` combined with the saturation threshold check.
- `decay_timer_current_value` reflects the timer register value and updates one cycle after `decay_enable_pulse`.

---

### 4.2 `trace_memory.v`

**Purpose:** Stores one 21-bit trace entry per neuron as described in Section 3.5. Supports one read and one write per clock cycle. Reads are asynchronous (combinational). Writes are synchronous.

**Parameters:**
- `NUM_NEURONS_PER_CLUSTER`
- `NEURON_ADDRESS_WIDTH`
- `TRACE_VALUE_BIT_WIDTH`
- `DECAY_TIMER_BIT_WIDTH`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `read_neuron_address` | `NEURON_ADDRESS_WIDTH` | Neuron index to read |
| output | `read_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value field of the addressed entry (combinational) |
| output | `read_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Stored timestamp of the addressed entry (combinational) |
| output | `read_trace_saturated_flag` | 1 | Saturation flag of the addressed entry (combinational) |
| input | `write_enable` | 1 | When high on a rising clock edge, write the new entry at `write_neuron_address` |
| input | `write_neuron_address` | `NEURON_ADDRESS_WIDTH` | Neuron index to write |
| input | `write_trace_value` | `TRACE_VALUE_BIT_WIDTH` | New trace value to store |
| input | `write_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | New timestamp to store |
| input | `write_trace_saturated_flag` | 1 | New saturation flag to store |

**Behavior:**
- Read is asynchronous: all three read output signals reflect the entry at `read_neuron_address` combinationally and update immediately when `read_neuron_address` changes.
- Write is synchronous: on the rising clock edge when `write_enable` is high, all three fields are written at `write_neuron_address`.
- On `reset`: all entries are initialized to `trace_value=0`, `trace_saturated_flag=1`, `trace_stored_timestamp=0`.
- Simultaneous read and write to the same address: the read outputs reflect the old value (before the write), and the new value is visible from the next cycle onward.

---

### 4.3 `trace_increase_logic.v` *(Swappable Module)*

**Purpose:** Computes the new trace value when a spike occurs and the trace must increase. This module is purely combinational and stateless. The port interface is fixed and must not be modified. Internal logic may be replaced in future design iterations.

**Parameters:**
- `TRACE_VALUE_BIT_WIDTH`
- `TRACE_INCREMENT_VALUE`
- `INCREASE_MODE` — selects between SET_MAX (0) and ADD_VALUE (1)

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `current_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value before spike-triggered increase |
| output | `increased_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value after spike-triggered increase |

**Behavior (default implementation):**
- When `INCREASE_MODE == 0` (SET_MAX): `increased_trace_value = {TRACE_VALUE_BIT_WIDTH{1'b1}}` — all bits set to 1, giving maximum value (255 for 8-bit trace).
- When `INCREASE_MODE == 1` (ADD_VALUE): `increased_trace_value = saturating_add(current_trace_value, TRACE_INCREMENT_VALUE)`. If the sum would exceed `2^TRACE_VALUE_BIT_WIDTH - 1`, clamp the result to `2^TRACE_VALUE_BIT_WIDTH - 1`.
- No clock, reset, or state of any kind.

---

### 4.4 `trace_update_module.v`

**Purpose:** A single self-contained processing unit that accepts one trace operation at a time. Two operation types are supported: INCREASE (spike has occurred, trace must go up) and DECAY_COMPUTE (trace value is needed for STDP, apply lazy decay to get effective current value). The barrel-shift-with-correction algorithm is used for decay. This module is parameterized and instantiated multiple times by the trace update arbiter.

**Parameters:**
- `TRACE_VALUE_BIT_WIDTH`
- `DECAY_TIMER_BIT_WIDTH`
- `TRACE_SATURATION_THRESHOLD`
- `DECAY_SHIFT_LOG2`
- `TRACE_INCREMENT_VALUE`
- `INCREASE_MODE` — passed through to internal `trace_increase_logic` instance

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `operation_start_pulse` | 1 | Asserted for one cycle to begin a new operation. Must only be asserted when `module_busy_flag` is low |
| input | `operation_type_select` | 1 | 0 = INCREASE operation. 1 = DECAY_COMPUTE operation |
| input | `input_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value read from trace memory, valid at the cycle `operation_start_pulse` is high |
| input | `input_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Stored timestamp from trace memory, valid at the cycle `operation_start_pulse` is high |
| input | `input_trace_saturated_flag` | 1 | Saturation flag from trace memory, valid at the cycle `operation_start_pulse` is high |
| input | `decay_timer_current_value` | `DECAY_TIMER_BIT_WIDTH` | Current global decay timer value, sampled at the cycle `operation_start_pulse` is high |
| output | `result_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Computed output trace value |
| output | `result_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | New timestamp to write back to trace memory |
| output | `result_trace_saturated_flag` | 1 | New saturation flag to write back to trace memory |
| output | `result_valid_pulse` | 1 | High for exactly one clock cycle when output results are valid |
| output | `module_busy_flag` | 1 | High while the module is processing. A new `operation_start_pulse` must not be issued while this is high |

**Behavior — INCREASE operation** (`operation_type_select = 0`):
1. On the rising clock edge when `operation_start_pulse` is high: capture `decay_timer_current_value` into an internal register (`captured_timestamp_register`).
2. Instantiate `trace_increase_logic` internally. Its `current_trace_value` input is driven by the registered `input_trace_value`. Its `increased_trace_value` output is registered into the result.
3. Output assignments: `result_trace_value = increased_trace_value`, `result_trace_stored_timestamp = captured_timestamp_register`, `result_trace_saturated_flag = 1'b0`.
4. This operation takes exactly 2 clock cycles: cycle 1 captures inputs; cycle 2 the result is registered and `result_valid_pulse` is asserted for one cycle.
5. `module_busy_flag` is asserted from the cycle `operation_start_pulse` is received through the cycle `result_valid_pulse` is asserted (inclusive).

**Behavior — DECAY_COMPUTE operation** (`operation_type_select = 1`):
1. On the rising clock edge when `operation_start_pulse` is high: capture all inputs into internal registers.
2. **Saturation flag check**: If the captured `input_trace_saturated_flag` is 1, skip all computation and proceed directly to the zero-output path (step 7).
3. **Delta-t computation**: Compute `delta_t_value = decay_timer_current_value - input_trace_stored_timestamp` as an unsigned `DECAY_TIMER_BIT_WIDTH`-bit subtraction. The natural two's complement overflow behavior of fixed-width unsigned subtraction correctly handles the case where the timer has wrapped once since the timestamp was stored.
4. **Saturation threshold check**: If `delta_t_value >= TRACE_SATURATION_THRESHOLD`, proceed to the zero-output path (step 7).
5. **Barrel-shift with correction**:
   - Compute `shift_amount_value = delta_t_value >> DECAY_SHIFT_LOG2`. This is a simple right-shift by `DECAY_SHIFT_LOG2` bits on the delta-t value and gives the number of bit positions to shift the trace value.
   - If `shift_amount_value >= TRACE_VALUE_BIT_WIDTH`, proceed to zero-output path (step 7).
   - Otherwise: `shifted_trace_value = input_trace_value >> shift_amount_value`.
   - **Correction step**: If `shift_amount_value > 0`, extract the correction bit: `correction_bit = (input_trace_value >> (shift_amount_value - 1)) & 1'b1`. If `correction_bit == 1'b1`, add 1 to `shifted_trace_value` with saturation at `2^TRACE_VALUE_BIT_WIDTH - 1`.
   - `result_trace_value = corrected_shifted_trace_value`.
   - `result_trace_saturated_flag = 1'b0`.
   - `result_trace_stored_timestamp = input_trace_stored_timestamp` — the timestamp is NOT updated during a decay read. It always reflects the moment of the last spike-triggered increase.
6. Proceed to step 8.
7. **Zero-output path**: `result_trace_value = 0`, `result_trace_saturated_flag = 1'b1`, `result_trace_stored_timestamp = input_trace_stored_timestamp`.
8. Register all result signals. Assert `result_valid_pulse` for exactly one cycle. De-assert `module_busy_flag`.
9. Total latency: 2 clock cycles from `operation_start_pulse` to `result_valid_pulse`, same as INCREASE.

**Note on shift_amount_value when shift_amount_value == 0**: When `shift_amount_value` is zero, no shift is applied and the correction step is skipped entirely (there is no bit below position 0 to extract). The trace value passes through unchanged.

---

### 4.5 `trace_update_arbiter.v`

**Purpose:** Manages a pool of `NUM_TRACE_UPDATE_MODULES` instances of `trace_update_module`. Accepts trace operation requests from the STDP controller, routes each request to the first available non-busy module, returns results tagged with the originating neuron address, and signals upstream when all modules are occupied.

**Parameters:**
- `NUM_TRACE_UPDATE_MODULES`
- `NEURON_ADDRESS_WIDTH`
- `TRACE_VALUE_BIT_WIDTH`
- `DECAY_TIMER_BIT_WIDTH`
- All parameters required by `trace_update_module` (passed through)

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `request_valid` | 1 | STDP controller asserts this for one cycle with a new request |
| input | `request_neuron_address` | `NEURON_ADDRESS_WIDTH` | Which neuron's trace this operation is for |
| input | `request_operation_type` | 1 | 0 = INCREASE, 1 = DECAY_COMPUTE |
| input | `request_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value read from trace memory for this request |
| input | `request_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Timestamp read from trace memory for this request |
| input | `request_trace_saturated_flag` | 1 | Saturation flag from trace memory for this request |
| input | `decay_timer_current_value` | `DECAY_TIMER_BIT_WIDTH` | Current global timer value, forwarded to all trace update module instances |
| output | `all_modules_busy_flag` | 1 | High when every module instance has `module_busy_flag` asserted. The STDP controller must not issue new requests while this is high |
| output | `result_valid` | 1 | High for one cycle when a result is available on the result outputs |
| output | `result_neuron_address` | `NEURON_ADDRESS_WIDTH` | Which neuron this result belongs to |
| output | `result_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Computed trace value from the completed operation |
| output | `result_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Resulting timestamp for write-back to trace memory |
| output | `result_trace_saturated_flag` | 1 | Resulting saturation flag for write-back |
| output | `result_operation_type` | 1 | Echo of the operation type of the completed operation (0=INCREASE, 1=DECAY_COMPUTE) |

**Internal structure:**
- Instantiate `NUM_TRACE_UPDATE_MODULES` instances of `trace_update_module`, indexed 0 to `NUM_TRACE_UPDATE_MODULES-1`.
- Maintain one `assigned_neuron_address_register` and one `assigned_operation_type_register` per module instance, to remember which request was dispatched to it (used for output tagging when result arrives).
- Maintain an output result FIFO of depth `NUM_TRACE_UPDATE_MODULES`. Each FIFO entry holds: `result_neuron_address`, `result_trace_value`, `result_trace_stored_timestamp`, `result_trace_saturated_flag`, `result_operation_type`. This handles the rare case where multiple modules complete on the same cycle.

**Behavior:**
- `all_modules_busy_flag` is the bitwise AND of all `module_busy_flag` outputs from all module instances.
- On each rising clock edge: when `request_valid` is high and `all_modules_busy_flag` is low, use a priority encoder (lowest index first) to find the first module instance whose `module_busy_flag` is low. Assert its `operation_start_pulse` for one cycle and present the request inputs to it. Store the `request_neuron_address` and `request_operation_type` into that instance's tag registers.
- Monitor all module `result_valid_pulse` outputs each cycle. For every module whose `result_valid_pulse` is high: construct a result entry from its outputs and the stored tag registers, and push it into the output result FIFO.
- Each cycle: if the output FIFO is non-empty, pop the head entry and present it on the result output ports with `result_valid` high. If the FIFO is empty, de-assert `result_valid`.

---

### 4.6 `banked_weight_memory.v`

**Purpose:** Implements the `NUM_WEIGHT_BANKS` physical memory banks that store the synaptic weight matrix. Supports simultaneous row reads across all banks, sequential column reads from one bank per cycle, and per-bank write operations. Each bank is an independent synchronous SRAM array.

**Parameters:**
- `NUM_WEIGHT_BANKS`
- `WEIGHT_BANK_ADDRESS_WIDTH`
- `WEIGHT_BIT_WIDTH`
- `NEURON_ADDRESS_WIDTH`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset. Initializes all weights to 0 |
| input | `row_read_enable` | 1 | When high: read the same address from all banks in parallel |
| input | `row_read_address` | `WEIGHT_BANK_ADDRESS_WIDTH` | Address to read across all banks. This equals the index of the fired post-synaptic neuron during STDP |
| output | `row_read_weight_data_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | Concatenated weight values from all banks. Bit slice `[B * WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH]` contains the weight from bank `B` |
| output | `row_read_data_valid` | 1 | High for one cycle, one cycle after `row_read_enable` is asserted |
| input | `column_read_enable` | 1 | When high: perform one step of sequential column read |
| input | `column_read_pre_neuron_address` | `NEURON_ADDRESS_WIDTH` | Index of the pre-synaptic neuron whose column of output weights is being read |
| input | `column_read_step_counter` | `NEURON_ADDRESS_WIDTH` | Current step `k`. Provided by the STDP controller. Represents the index of the post-synaptic neuron being targeted in this step |
| output | `column_read_weight_output` | `WEIGHT_BIT_WIDTH` | Weight value `W[k][j]` returned from the column read step |
| output | `column_read_target_neuron_index` | `NEURON_ADDRESS_WIDTH` | Echo of `column_read_step_counter`, indicating which post-synaptic neuron this weight is for |
| output | `column_read_data_valid` | 1 | High for one cycle, one cycle after `column_read_enable` is asserted |
| input | `weight_write_enable_per_bank` | `NUM_WEIGHT_BANKS` | One write enable bit per bank. When bit `B` is high, bank `B` is written |
| input | `weight_write_address` | `WEIGHT_BANK_ADDRESS_WIDTH` | Address to write in all enabled banks. During STDP this equals the fired post-synaptic neuron index |
| input | `weight_write_data_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | New weight data for all banks. Only banks with their bit set in `weight_write_enable_per_bank` are written |

**Behavior:**
- Internally instantiate `NUM_WEIGHT_BANKS` independent synchronous SRAM arrays. Each bank has `2^WEIGHT_BANK_ADDRESS_WIDTH` entries of `WEIGHT_BIT_WIDTH` bits.
- **Row read**: On the rising clock edge when `row_read_enable` is high, all banks simultaneously register their read address as `row_read_address`. One cycle later, all banks present their stored value and `row_read_data_valid` is asserted for one cycle.
- **Column read**: On the rising clock edge when `column_read_enable` is high, compute `target_bank_index_for_column = column_read_step_counter + column_read_pre_neuron_address`. Because both operands and the sum are `NEURON_ADDRESS_WIDTH` bits wide and `NUM_WEIGHT_BANKS` is a power of two, the addition overflow truncates naturally to perform the mod operation. Bank `target_bank_index_for_column` is read at address `column_read_step_counter`. One cycle later, `column_read_weight_output` is valid and `column_read_data_valid` is asserted for one cycle. `column_read_target_neuron_index` echoes `column_read_step_counter` registered by one cycle.
- **Write**: On the rising clock edge, for each bank `B` where `weight_write_enable_per_bank[B]` is high, write `weight_write_data_bus[B * WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH]` to address `weight_write_address` in bank `B`. Multiple banks may be written in the same cycle independently.
- **Column read and row read active simultaneously**: Both are permitted. Column read targets only one specific bank; row read targets all banks. There is no structural conflict. Both proceed independently and both `_data_valid` signals may be high simultaneously the following cycle.
- **Row read and write to the same bank in the same cycle**: The write takes priority (write-before-read). The row read result for the affected bank reflects the newly written value on the following cycle. The STDP controller is designed to avoid this situation in normal operation, but the memory must behave consistently if it occurs.

---

### 4.7 `weight_update_logic.v` *(Swappable Module)*

**Purpose:** Computes the new weight value for a single synapse during an STDP event, given the pre-synaptic trace, post-synaptic trace, and current weight. This module is purely combinational. The port interface is fixed and must not be modified.

**Parameters:**
- `WEIGHT_BIT_WIDTH`
- `TRACE_VALUE_BIT_WIDTH`
- `LTP_SHIFT_AMOUNT`
- `LTD_SHIFT_AMOUNT`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `pre_synaptic_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Effective trace of the pre-synaptic neuron after lazy decay has been applied |
| input | `post_synaptic_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Effective trace of the fired post-synaptic neuron after lazy decay has been applied |
| input | `current_weight_value` | `WEIGHT_BIT_WIDTH` | Current synaptic weight before update |
| output | `updated_weight_value` | `WEIGHT_BIT_WIDTH` | New synaptic weight after STDP rule is applied |

**Behavior (default implementation):**
- **LTP condition** (Long-Term Potentiation — synapse strengthened): if `pre_synaptic_trace_value > 0`, the pre-synaptic neuron fired before the post-synaptic neuron and was causally involved.
  - `weight_change_magnitude = pre_synaptic_trace_value >> LTP_SHIFT_AMOUNT`
  - `updated_weight_value = saturating_add(current_weight_value, weight_change_magnitude)` — result clamped at `2^WEIGHT_BIT_WIDTH - 1`.
- **LTD condition** (Long-Term Depression — synapse weakened): if `pre_synaptic_trace_value == 0`, the pre-synaptic neuron had no recent activity and was not causally correlated.
  - `weight_change_magnitude = post_synaptic_trace_value >> LTD_SHIFT_AMOUNT`
  - `updated_weight_value = saturating_subtract(current_weight_value, weight_change_magnitude)` — result clamped at `0`.
- Entirely combinational. No clock, reset, or internal state.

---

### 4.8 `weight_update_logic_bank_array.v`

**Purpose:** Instantiates `NUM_WEIGHT_BANKS` copies of `weight_update_logic` operating in parallel. One copy per bank. All copies receive inputs and produce outputs in the same clock cycle. This module is used by the STDP controller to update all synaptic weights in one logical step.

**Parameters:**
- `NUM_WEIGHT_BANKS`
- All parameters required by `weight_update_logic`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `all_banks_pre_synaptic_trace_bus` | `NUM_WEIGHT_BANKS * TRACE_VALUE_BIT_WIDTH` | Pre-synaptic trace for each bank's corresponding synapse. Slice `[B * TRACE_VALUE_BIT_WIDTH +: TRACE_VALUE_BIT_WIDTH]` is the pre-synaptic trace for bank `B` |
| input | `post_synaptic_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Post-synaptic trace of the fired neuron. Same value broadcast to all bank instances |
| input | `all_banks_current_weight_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | Current weight values from the row read. Slice `[B * WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH]` is the current weight for bank `B` |
| output | `all_banks_updated_weight_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | Updated weight values for all banks. Slice `[B * WEIGHT_BIT_WIDTH +: WEIGHT_BIT_WIDTH]` is the updated weight for bank `B` |

**Behavior:** Purely combinational. Each of the `NUM_WEIGHT_BANKS` instances of `weight_update_logic` receives its individual slice of `all_banks_pre_synaptic_trace_bus` and `all_banks_current_weight_bus`, plus the shared `post_synaptic_trace_value`, and contributes its result to the corresponding slice of `all_banks_updated_weight_bus`. No clock or reset.

---

### 4.9 `cluster_connection_matrix.v`

**Purpose:** Stores the 2-bit connection descriptor for every neuron pair within the cluster. Given a row address (a neuron of interest), the module outputs two vectors simultaneously: one describing which neurons are inputs to that neuron (MSB of each entry), and one describing which neurons that neuron outputs to (LSB of each entry).

**Parameters:**
- `NUM_NEURONS_PER_CLUSTER`
- `NEURON_ADDRESS_WIDTH`

**Storage layout:**
- Internal 2D register array: `connection_table[NUM_NEURONS_PER_CLUSTER - 1 : 0][NUM_NEURONS_PER_CLUSTER - 1 : 0]`, each entry is 2 bits.
- For entry `connection_table[row_neuron][column_neuron]`:
  - Bit `[1]` (MSB): value `1` means `column_neuron` is a pre-synaptic input to `row_neuron`.
  - Bit `[0]` (LSB): value `1` means `row_neuron` sends its output to `column_neuron` (i.e., `row_neuron` is pre-synaptic to `column_neuron`).
- Total storage: `NUM_NEURONS_PER_CLUSTER^2 × 2` bits.

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset. Clears all entries to 0 |
| input | `read_row_neuron_address` | `NEURON_ADDRESS_WIDTH` | The neuron index whose connection row is to be read |
| output | `row_input_connection_vector` | `NUM_NEURONS_PER_CLUSTER` | For each column neuron `j`: bit `j` is the MSB of `connection_table[read_row_neuron_address][j]`. A value of 1 means neuron `j` is an input to the row neuron |
| output | `row_output_connection_vector` | `NUM_NEURONS_PER_CLUSTER` | For each column neuron `j`: bit `j` is the LSB of `connection_table[read_row_neuron_address][j]`. A value of 1 means the row neuron sends output to neuron `j` |
| output | `row_data_valid` | 1 | High for one cycle, one cycle after `read_row_neuron_address` is presented (registered output) |
| input | `write_enable` | 1 | When high on a rising clock edge, write one entry |
| input | `write_row_neuron_address` | `NEURON_ADDRESS_WIDTH` | Row address of the entry to write |
| input | `write_column_neuron_address` | `NEURON_ADDRESS_WIDTH` | Column address of the entry to write |
| input | `write_connection_bits` | 2 | 2-bit value to write into `connection_table[write_row][write_column]` |

**Behavior:**
- Read is registered: `row_data_valid` goes high one cycle after `read_row_neuron_address` is presented. Both `row_input_connection_vector` and `row_output_connection_vector` are valid when `row_data_valid` is high.
- Write is synchronous and independent of read. Both may occur in the same cycle without conflict unless they target the same entry, in which case the write takes effect from the next cycle.
- On `reset`: all entries cleared to 2'b00.

---

### 4.10 `neuron_index_to_address_encoder.v`

**Purpose:** Converts a one-hot neuron spike bus into a binary neuron address. When a neuron fires, its index in the cluster maps to a binary address used throughout the STDP pipeline.

**Parameters:**
- `NUM_NEURONS_PER_CLUSTER`
- `NEURON_ADDRESS_WIDTH`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `one_hot_spike_input_bus` | `NUM_NEURONS_PER_CLUSTER` | One-hot bus: exactly one bit high under normal operation |
| output | `binary_neuron_address_output` | `NEURON_ADDRESS_WIDTH` | Binary-encoded index of the active (high) bit |
| output | `any_spike_detected` | 1 | High if any bit in `one_hot_spike_input_bus` is high (OR of all bits) |

**Behavior:** Entirely combinational priority encoder. If multiple bits are high (should not occur after queue arbitration), the lowest-index high bit determines the output. No clock, reset, or internal state.

---

### 4.11 `spike_input_queue.v`

**Purpose:** Handles simultaneous spikes from multiple neurons in the same cluster. When multiple spikes arrive on the same cycle, they are enqueued as binary addresses and released one at a time to the STDP controller. While the queue is non-empty, all cluster neurons are frozen to prevent new spikes from interleaving with the in-progress STDP pipeline.

**Parameters:**
- `NUM_NEURONS_PER_CLUSTER`
- `NEURON_ADDRESS_WIDTH`
- `SPIKE_QUEUE_DEPTH`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `incoming_spike_bus` | `NUM_NEURONS_PER_CLUSTER` | Raw spike output bus from all neuron instances in the cluster, sampled every cycle |
| output | `cluster_freeze_enable` | 1 | High whenever the queue is non-empty. All neuron `enable` inputs must be driven low when this is high |
| output | `dequeued_spike_neuron_address` | `NEURON_ADDRESS_WIDTH` | Binary address of the next spike to be processed, presented from the head of the FIFO |
| output | `dequeued_spike_valid` | 1 | High whenever the queue is non-empty and `dequeued_spike_neuron_address` holds a valid entry |
| input | `dequeue_acknowledge` | 1 | STDP controller asserts this for one cycle to pop the head entry and advance to the next |
| output | `queue_empty_flag` | 1 | High when no spikes are pending |
| output | `queue_full_flag` | 1 | High when the queue is full and cannot accept new entries |

**Behavior:**
- On each rising clock edge: examine `incoming_spike_bus`. For each bit that is high, encode its index to a binary address and push it into the FIFO if there is space. Multiple bits may be high simultaneously; process them from lowest index to highest, pushing one per cycle or using combinational priority to push all in one cycle depending on available space. Preferred implementation: push all detected spikes in one cycle using a combinational scan, using a bitmask to avoid double-pushing already-enqueued entries from the same burst.
- `cluster_freeze_enable = !queue_empty_flag`. This is registered to prevent glitches.
- The FIFO head is always visible on `dequeued_spike_neuron_address` when `dequeued_spike_valid` is high.
- On `dequeue_acknowledge`: pop the head entry. If more entries remain, `dequeued_spike_valid` re-asserts immediately on the next clock cycle.
- Implemented as a circular buffer with `head_pointer_register` and `tail_pointer_register`, each `$clog2(SPIKE_QUEUE_DEPTH)`  bits wide, with an `entry_count_register` for empty/full detection.
- On `reset`: all pointers cleared to 0, queue empty.

---

### 4.12 `stdp_controller.v`

**Purpose:** The central finite state machine that orchestrates the complete STDP pipeline and weight distribution cycle triggered by a single neuron firing. Coordinates reading the cluster connection matrix, issuing trace operations to the arbiter, reading and writing the banked weight memory, computing updated weights, distributing output weights to post-synaptic neurons, and writing back results. Uses `busy`/`valid` handshaking throughout. The duration of each STDP cycle is variable and data-dependent.

**Parameters:** All global system parameters listed in Section 2.

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `fired_neuron_address` | `NEURON_ADDRESS_WIDTH` | Address of the neuron whose spike event is being processed |
| input | `fired_neuron_address_valid` | 1 | High when `fired_neuron_address` holds a pending spike to process (driven by spike queue's `dequeued_spike_valid`) |
| output | `fired_neuron_address_acknowledge` | 1 | Pulsed high for one cycle to tell the spike queue that this spike has been accepted for processing |
| input | `decay_timer_current_value` | `DECAY_TIMER_BIT_WIDTH` | From `global_decay_timer` |
| output | `trace_memory_read_neuron_address` | `NEURON_ADDRESS_WIDTH` | Address sent to `trace_memory` for a read operation |
| input | `trace_memory_read_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value returned from `trace_memory` |
| input | `trace_memory_read_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Timestamp returned from `trace_memory` |
| input | `trace_memory_read_saturated_flag` | 1 | Saturation flag returned from `trace_memory` |
| output | `trace_memory_write_enable` | 1 | Write enable to `trace_memory` |
| output | `trace_memory_write_neuron_address` | `NEURON_ADDRESS_WIDTH` | Write address to `trace_memory` |
| output | `trace_memory_write_trace_value` | `TRACE_VALUE_BIT_WIDTH` | New trace value to write |
| output | `trace_memory_write_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | New timestamp to write |
| output | `trace_memory_write_saturated_flag` | 1 | New saturation flag to write |
| output | `arbiter_request_valid` | 1 | Assert to issue a request to `trace_update_arbiter` |
| output | `arbiter_request_neuron_address` | `NEURON_ADDRESS_WIDTH` | Neuron address for the trace operation |
| output | `arbiter_request_operation_type` | 1 | 0 = INCREASE, 1 = DECAY_COMPUTE |
| output | `arbiter_request_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Trace value from trace memory for this request |
| output | `arbiter_request_trace_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Timestamp from trace memory for this request |
| output | `arbiter_request_trace_saturated_flag` | 1 | Saturation flag from trace memory for this request |
| input | `arbiter_all_modules_busy_flag` | 1 | Stall signal from `trace_update_arbiter` |
| input | `arbiter_result_valid` | 1 | High for one cycle when a result is ready from `trace_update_arbiter` |
| input | `arbiter_result_neuron_address` | `NEURON_ADDRESS_WIDTH` | Which neuron's trace result this is |
| input | `arbiter_result_trace_value` | `TRACE_VALUE_BIT_WIDTH` | Resulting trace value |
| input | `arbiter_result_stored_timestamp` | `DECAY_TIMER_BIT_WIDTH` | Resulting timestamp for write-back |
| input | `arbiter_result_saturated_flag` | 1 | Resulting saturation flag for write-back |
| input | `arbiter_result_operation_type` | 1 | Operation type echo (0=INCREASE, 1=DECAY_COMPUTE) |
| output | `connection_matrix_read_row_address` | `NEURON_ADDRESS_WIDTH` | Row address for `cluster_connection_matrix` |
| input | `connection_matrix_row_input_vector` | `NUM_NEURONS_PER_CLUSTER` | MSB vector from connection matrix (which neurons are inputs) |
| input | `connection_matrix_row_output_vector` | `NUM_NEURONS_PER_CLUSTER` | LSB vector from connection matrix (which neurons receive output) |
| input | `connection_matrix_row_data_valid` | 1 | Valid signal from `cluster_connection_matrix` |
| output | `weight_bank_row_read_enable` | 1 | Row read enable to `banked_weight_memory` |
| output | `weight_bank_row_read_address` | `WEIGHT_BANK_ADDRESS_WIDTH` | Address for row read (= fired neuron address) |
| input | `weight_bank_row_weight_data_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | All weights returned from row read |
| input | `weight_bank_row_data_valid` | 1 | Valid signal from row read |
| output | `weight_bank_column_read_enable` | 1 | Column read enable to `banked_weight_memory` |
| output | `weight_bank_column_pre_neuron_address` | `NEURON_ADDRESS_WIDTH` | Pre-synaptic neuron address for column read |
| output | `weight_bank_column_step_counter` | `NEURON_ADDRESS_WIDTH` | Current step k for column read |
| input | `weight_bank_column_weight_output` | `WEIGHT_BIT_WIDTH` | Weight value from column read step |
| input | `weight_bank_column_target_neuron_index` | `NEURON_ADDRESS_WIDTH` | Post-synaptic neuron index for this column read result |
| input | `weight_bank_column_data_valid` | 1 | Valid from column read |
| output | `weight_bank_write_enable_per_bank` | `NUM_WEIGHT_BANKS` | Per-bank write enable for STDP weight write-back |
| output | `weight_bank_write_address` | `WEIGHT_BANK_ADDRESS_WIDTH` | Write address (= fired neuron address) |
| output | `weight_bank_write_data_bus` | `NUM_WEIGHT_BANKS * WEIGHT_BIT_WIDTH` | Updated weights to write back to all banks |
| output | `weight_distribution_bus_data` | `WEIGHT_BIT_WIDTH` | Weight value being placed on the distribution bus |
| output | `weight_distribution_bus_target_neuron_address` | `NEURON_ADDRESS_WIDTH` | Which post-synaptic neuron this weight is destined for |
| output | `weight_distribution_bus_valid` | 1 | High when distribution bus outputs are valid this cycle |
| output | `stdp_controller_busy_flag` | 1 | High for the entire duration of processing any spike event |

**State Machine:**

**State: STDP_CTRL_IDLE**
- All output enables de-asserted. `stdp_controller_busy_flag` low.
- When `fired_neuron_address_valid` is high: register `fired_neuron_address` into `registered_fired_neuron_address_register`. Assert `fired_neuron_address_acknowledge` for one cycle. Assert `stdp_controller_busy_flag`. Transition to `STDP_CTRL_READ_CONNECTION_MATRIX`.

**State: STDP_CTRL_READ_CONNECTION_MATRIX**
- Assert `connection_matrix_read_row_address = registered_fired_neuron_address_register`.
- Simultaneously: set `trace_memory_read_neuron_address = registered_fired_neuron_address_register` to read the fired neuron's own trace. On the following cycle (trace memory is async), issue `arbiter_request_valid` with the fired neuron's trace data and `arbiter_request_operation_type = 0` (INCREASE). This increases the post-synaptic trace before any weight update occurs.
- Wait for `connection_matrix_row_data_valid`. When asserted: register `connection_matrix_row_input_vector` into `registered_input_connection_vector_register` and `connection_matrix_row_output_vector` into `registered_output_connection_vector_register`.
- Initialize `column_step_counter_register = 0`.
- Initialize `pending_trace_result_count_register` to count the number of set bits in `registered_input_connection_vector_register` plus 1 (for the post-synaptic INCREASE operation).
- Initialize `received_trace_result_count_register = 0`.
- Transition to `STDP_CTRL_BEGIN_PARALLEL_PHASE`.

**State: STDP_CTRL_BEGIN_PARALLEL_PHASE**
- Assert `weight_bank_row_read_enable` with `weight_bank_row_read_address = registered_fired_neuron_address_register`. This reads all current input weights for the fired neuron simultaneously.
- Assert `weight_bank_column_read_enable`, `weight_bank_column_pre_neuron_address = registered_fired_neuron_address_register`, `weight_bank_column_step_counter = 0`. This begins weight distribution to post-synaptic neurons.
- Transition to `STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES`.

**State: STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES**

This state handles two parallel activities simultaneously and runs for a variable number of cycles.

*Activity A — Weight Distribution to Post-Synaptic Neurons:*
- Each cycle when `weight_bank_column_data_valid` is high: examine `registered_output_connection_vector_register[weight_bank_column_target_neuron_index]`. If this bit is 1 (the row neuron connects to this post-synaptic neuron): assert `weight_distribution_bus_valid`, place `weight_bank_column_weight_output` on `weight_distribution_bus_data`, and `weight_bank_column_target_neuron_index` on `weight_distribution_bus_target_neuron_address`. If the bit is 0 (not connected), simply do not assert `weight_distribution_bus_valid` for this cycle.
- Increment `column_step_counter_register` each time a column read result arrives. Issue the next `weight_bank_column_read_enable` with the incremented counter.
- Activity A completes when `column_step_counter_register` reaches `NUM_NEURONS_PER_CLUSTER`.

*Activity B — Pre-Synaptic Trace Fetches:*
- Maintain a `pre_trace_request_pointer_register` initialized to 0 (scans through neuron indices).
- Each cycle: scan `registered_input_connection_vector_register` starting from `pre_trace_request_pointer_register` to find the next set bit. When found: read that neuron's trace from `trace_memory`, then in the following cycle issue an `arbiter_request_valid` with `arbiter_request_operation_type = 1` (DECAY_COMPUTE). Only issue when `arbiter_all_modules_busy_flag` is low. If arbiter is busy, hold the request and retry next cycle without advancing the pointer.
- Advance `pre_trace_request_pointer_register` after each successful request issuance.
- Activity B completes when all set bits in `registered_input_connection_vector_register` have had their trace requests issued.

*Transition condition:*
- When both Activity A is complete (all column steps done) AND Activity B is complete (all trace requests issued): transition to `STDP_CTRL_WAIT_FOR_TRACE_RESULTS`.

**State: STDP_CTRL_WAIT_FOR_TRACE_RESULTS**
- Wait for arbiter results. Each cycle `arbiter_result_valid` is high: if `arbiter_result_operation_type == 1` (DECAY_COMPUTE): store `arbiter_result_trace_value` in `pre_synaptic_trace_result_store_register[arbiter_result_neuron_address]`. Write the updated trace entry (with the corrected saturation and timestamp) back to trace memory via `trace_memory_write_enable`. Increment `received_trace_result_count_register`.
- If `arbiter_result_operation_type == 0` (INCREASE — post-synaptic trace): store `arbiter_result_trace_value` in `post_synaptic_trace_result_register`. Write this updated trace back to trace memory.
- When `received_trace_result_count_register == pending_trace_result_count_register`: all results are in. Transition to `STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS`.
- Note: `weight_bank_row_data_valid` may have asserted during an earlier state. If so, the row read data bus is already registered. If `weight_bank_row_data_valid` has not yet been seen when entering this state, wait for it here as well before transitioning.

**State: STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS**
- The `weight_update_logic_bank_array` module is instantiated as combinational logic wired continuously to this controller's registers. In this state, its inputs are valid:
  - `post_synaptic_trace_value = post_synaptic_trace_result_register`
  - For each bank `B`: `pre_synaptic_trace` slice = `pre_synaptic_trace_result_store_register[(B - registered_fired_neuron_address_register + NUM_WEIGHT_BANKS) % NUM_WEIGHT_BANKS]`
  - For each bank `B`: `current_weight` slice = registered row read data from `weight_bank_row_weight_data_bus_register`
- Register the `all_banks_updated_weight_bus` output from `weight_update_logic_bank_array`.
- Assert `weight_bank_write_enable_per_bank = {NUM_WEIGHT_BANKS{1'b1}}` (all banks), `weight_bank_write_address = registered_fired_neuron_address_register`, `weight_bank_write_data_bus = registered updated weight bus`.
- **Conflict avoidance**: If `weight_bank_column_data_valid` is also high this cycle (a column read is still in progress — should not normally happen but must be handled), delay the write by one cycle.
- After the write is issued: transition to `STDP_CTRL_IDLE`.

**Internal registers required in STDP controller:**
- `registered_fired_neuron_address_register` : `NEURON_ADDRESS_WIDTH` bits
- `registered_input_connection_vector_register` : `NUM_NEURONS_PER_CLUSTER` bits
- `registered_output_connection_vector_register` : `NUM_NEURONS_PER_CLUSTER` bits
- `column_step_counter_register` : `NEURON_ADDRESS_WIDTH` bits
- `pre_trace_request_pointer_register` : `NEURON_ADDRESS_WIDTH` bits
- `pending_trace_result_count_register` : `$clog2(NUM_NEURONS_PER_CLUSTER + 1)` bits
- `received_trace_result_count_register` : `$clog2(NUM_NEURONS_PER_CLUSTER + 1)` bits
- `pre_synaptic_trace_result_store_register` : `NUM_NEURONS_PER_CLUSTER × TRACE_VALUE_BIT_WIDTH` bits (indexed by neuron address)
- `post_synaptic_trace_result_register` : `TRACE_VALUE_BIT_WIDTH` bits
- `weight_bank_row_weight_data_bus_register` : `NUM_WEIGHT_BANKS × WEIGHT_BIT_WIDTH` bits (latches row read result when valid)
- `row_read_data_captured_flag_register` : 1 bit (set when row read result has been latched)

---

### 4.13 `weight_distribution_receiver.v`

**Purpose:** One instance of this module exists per neuron in the cluster. It monitors the shared weight distribution bus and captures the weight when the bus addresses this specific neuron. It holds the captured weight in a register until the neuron's logic consumes it.

**Parameters:**
- `WEIGHT_BIT_WIDTH`
- `NEURON_ADDRESS_WIDTH`
- `THIS_NEURON_ADDRESS` — an integer parameter set uniquely per instance at instantiation time, from 0 to `NUM_NEURONS_PER_CLUSTER - 1`

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `distribution_bus_weight_data` | `WEIGHT_BIT_WIDTH` | Shared weight value from the distribution bus |
| input | `distribution_bus_target_neuron_address` | `NEURON_ADDRESS_WIDTH` | Which neuron the distribution bus is currently addressing |
| input | `distribution_bus_valid` | 1 | High when the distribution bus outputs are valid this cycle |
| output | `held_weight_value` | `WEIGHT_BIT_WIDTH` | Held weight register value for this neuron |
| output | `held_weight_valid_flag` | 1 | High when a weight has been received and is waiting to be consumed |
| input | `weight_consumed_acknowledge` | 1 | Driven by the neuron instance: asserted for one cycle when the neuron has consumed the held weight |

**Behavior:**
- When `distribution_bus_valid` is high AND `distribution_bus_target_neuron_address == THIS_NEURON_ADDRESS` (parameter comparison): on the rising clock edge, capture `distribution_bus_weight_data` into `held_weight_value_register` and assert `held_weight_valid_flag_register`.
- `held_weight_valid_flag_register` is cleared (de-asserted) on the rising clock edge following a cycle where `weight_consumed_acknowledge` is high.
- If a new weight arrives while `held_weight_valid_flag_register` is still high: overwrite `held_weight_value_register` with the new value. This is acceptable because the neuron should have consumed the previous weight before the next STDP distribution cycle begins (the cluster freeze mechanism ensures this in normal operation).
- On `reset`: `held_weight_value_register = 0`, `held_weight_valid_flag_register = 0`.

---

### 4.14 `neuron_cluster.v`

**Purpose:** Top-level integration module for one complete cluster. Instantiates the neuron core array and all supporting subsystems. This is the main module delivered to the top-level system.

**Parameters:** All global system parameters.

**Ports:**

| Direction | Name | Width | Description |
|---|---|---|---|
| input | `clock` | 1 | System clock |
| input | `reset` | 1 | Synchronous active-high reset |
| input | `global_cluster_enable` | 1 | When low: all neurons in the cluster are disabled (frozen in time) |
| input | `decay_enable_pulse` | 1 | Forwarded to `global_decay_timer` |
| input | `external_spike_input_bus` | `NUM_NEURONS_PER_CLUSTER` | Optional external spike signals arriving from outside this cluster |
| output | `cluster_spike_output_bus` | `NUM_NEURONS_PER_CLUSTER` | Spike output signals from all neuron instances |
| output | `cluster_busy_flag` | 1 | High while any STDP or queued spike processing is in progress |

**Internal wiring rules:**

- Instantiate `NUM_NEURONS_PER_CLUSTER` neuron core instances. For neuron instance `i`:
  - `.clock` → cluster `clock`
  - `.reset` → cluster `reset`
  - `.enable` → `global_cluster_enable AND NOT cluster_freeze_enable` (where `cluster_freeze_enable` comes from `spike_input_queue`)
  - `.input_spike_wire` → `weight_distribution_receiver_instance[i].held_weight_valid_flag` (a spike is presented to the neuron when a valid weight arrives — this serves as the input spike signal driving the neuron's integration)
  - `.weight_input` → `weight_distribution_receiver_instance[i].held_weight_value`
  - `.spike_output_wire` → bit `i` of the cluster spike output bus AND into `spike_input_queue.incoming_spike_bus[i]`

- Instantiate one `weight_distribution_receiver` per neuron, with `THIS_NEURON_ADDRESS = i` for instance `i`. The `weight_consumed_acknowledge` input of each receiver is connected to the corresponding neuron's `input_spike_wire` signal (when the neuron accepts the weight, acknowledge it).

- The `spike_input_queue` output `dequeued_spike_neuron_address` and `dequeued_spike_valid` connect directly to `stdp_controller` inputs `fired_neuron_address` and `fired_neuron_address_valid`. The `dequeue_acknowledge` input of the queue connects to `stdp_controller` output `fired_neuron_address_acknowledge`.

- `cluster_busy_flag = stdp_controller_busy_flag OR NOT queue_empty_flag`

- All `weight_distribution_bus_*` outputs of `stdp_controller` are fanned out to all `weight_distribution_receiver` instances.

- `global_decay_timer` is instantiated inside `neuron_cluster`. Its `decay_timer_current_value` is routed to `trace_update_arbiter` (and through it to all `trace_update_module` instances) and to `stdp_controller`.

---

## 5. File List Summary

The following Verilog files must be created. Each file contains exactly one module. File name matches module name.

| File Name | Module Name | Notes |
|---|---|---|
| `global_decay_timer.v` | `global_decay_timer` | |
| `trace_memory.v` | `trace_memory` | |
| `trace_increase_logic.v` | `trace_increase_logic` | **Swappable** |
| `trace_update_module.v` | `trace_update_module` | Instantiates `trace_increase_logic` |
| `trace_update_arbiter.v` | `trace_update_arbiter` | Instantiates `NUM_TRACE_UPDATE_MODULES` × `trace_update_module` |
| `banked_weight_memory.v` | `banked_weight_memory` | |
| `weight_update_logic.v` | `weight_update_logic` | **Swappable** |
| `weight_update_logic_bank_array.v` | `weight_update_logic_bank_array` | Instantiates `NUM_WEIGHT_BANKS` × `weight_update_logic` |
| `cluster_connection_matrix.v` | `cluster_connection_matrix` | |
| `neuron_index_to_address_encoder.v` | `neuron_index_to_address_encoder` | |
| `spike_input_queue.v` | `spike_input_queue` | |
| `stdp_controller.v` | `stdp_controller` | Instantiates `weight_update_logic_bank_array` as combinational |
| `weight_distribution_receiver.v` | `weight_distribution_receiver` | |
| `neuron_cluster.v` | `neuron_cluster` | Top-level. Instantiates all above modules plus the pre-existing `neuron.v` |

The pre-existing neuron module (`neuron.v`) is not to be created. It must be instantiated inside `neuron_cluster.v` using the port mapping described in Section 4.14.

---

## 6. Banked Memory Addressing — Quick Reference

```
Conceptual matrix entry: W[post_neuron_index][pre_neuron_index]
  Physical location:
    Bank Index B = (post_neuron_index + pre_neuron_index) mod NUM_WEIGHT_BANKS
    Address A    = post_neuron_index

What Bank B at Address A stores:
    W[A][(B - A + NUM_WEIGHT_BANKS) mod NUM_WEIGHT_BANKS]

ROW READ — reading all input weights for fired post-synaptic neuron i (STDP):
    Action : read address i from ALL banks simultaneously
    Bank B returns : W[i][(B - i + NUM_WEIGHT_BANKS) % NUM_WEIGHT_BANKS]
    Pre-neuron index of Bank B result : (B - i + NUM_WEIGHT_BANKS) % NUM_WEIGHT_BANKS
    Hardware : NEURON_ADDRESS_WIDTH-bit subtraction, overflow = natural mod

COLUMN READ — distributing output weights of fired pre-synaptic neuron j:
    Action : sequential, one step per clock cycle
    Step k : read Bank (k + j) % NUM_WEIGHT_BANKS at Address k
    Result : W[k][j], destined for post-synaptic neuron k
    Hardware : NEURON_ADDRESS_WIDTH-bit addition overflow = natural mod
    Total cycles : NUM_NEURONS_PER_CLUSTER
```

---

## 7. Trace Entry Timing and Decay Quick Reference

```
Trace entry storage (21 bits per neuron):
    [20]    = trace_saturated_flag
    [19:8]  = trace_stored_timestamp  (12 bits, value of decay timer at last spike)
    [7:0]   = trace_value             (8 bits, raw value at last spike)

Effective trace at query time:
    delta_t = (decay_timer_current_value - trace_stored_timestamp)  [12-bit unsigned mod subtraction]

    if trace_saturated_flag == 1 :        effective_trace = 0
    elif delta_t >= TRACE_SATURATION_THRESHOLD :  effective_trace = 0, set saturated
    else :
        shift_amount = delta_t >> DECAY_SHIFT_LOG2
        if shift_amount >= TRACE_VALUE_BIT_WIDTH : effective_trace = 0, set saturated
        else :
            shifted = trace_value >> shift_amount
            if shift_amount > 0 and ((trace_value >> (shift_amount - 1)) & 1) == 1 :
                shifted = saturating_add(shifted, 1)
            effective_trace = shifted

Timestamp write-back:
    INCREASE operation : write new timestamp = current decay_timer_current_value, clear saturated flag
    DECAY_COMPUTE operation : timestamp is NOT updated (keep stored_timestamp as-is)
```

---

## 8. Critical Implementation Notes

1. **All mod operations use natural overflow.** Because `NUM_WEIGHT_BANKS` and `NUM_NEURONS_PER_CLUSTER` are always powers of two, modular arithmetic in bank index computation, column step bank selection, and pre-neuron index recovery is achieved by simply using `NEURON_ADDRESS_WIDTH`-bit arithmetic and allowing addition/subtraction to overflow naturally. No division, no remainder circuit, no explicit modulo operator.

2. **Timestamp subtraction is safe for single-generation wraps.** The 12-bit unsigned subtraction `delta_t = current_time - stored_time` produces a mathematically correct positive result even after one timer wrap, because two's complement unsigned subtraction handles this case correctly. The `TRACE_SATURATION_THRESHOLD` catches cases where delta_t is so large the trace would be zero anyway, making multi-wrap ambiguity irrelevant in practice. The system is designed such that a trace is never left unread long enough to be ambiguous across more than one timer generation.

3. **Post-synaptic trace increase occurs before weight update.** The INCREASE operation for the fired neuron's own trace is dispatched in `STDP_CTRL_READ_CONNECTION_MATRIX`, before any weight computation begins. The returned increased trace value from the arbiter is the post-synaptic trace value used in `weight_update_logic`. This ensures the STDP rule always computes with the post-synaptic trace including the current spike contribution.

4. **Pre-synaptic traces are read with lazy decay, not the stored raw value.** When the STDP controller issues DECAY_COMPUTE requests to the arbiter, the effective (decayed) trace values that come back are what get stored in `pre_synaptic_trace_result_store_register` and subsequently fed to `weight_update_logic`. The raw stored values are never directly used for weight computation.

5. **Connection vectors gate trace requests.** Only neurons with their bit set in `registered_input_connection_vector_register` have their pre-synaptic traces fetched. The `pending_trace_result_count_register` is initialized to the popcount of this vector plus one (for the post-synaptic INCREASE). This popcount can be computed combinationally using a simple adder tree.

6. **Neuron freeze is immediate.** `cluster_freeze_enable` from `spike_input_queue` must be combinationally fed to the `enable` gating logic of all neurons with no registered delay. A one-cycle delay could allow an additional spike to enter the queue before freeze takes effect.

7. **Weight distribution and STDP weight write-back are serialized by state.** Weight distribution (column reads) runs in `STDP_CTRL_DISTRIBUTE_WEIGHTS_AND_FETCH_TRACES`. Weight write-back happens only in `STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS`, which is entered after column reads are complete. By state ordering, the two memory operations on the weight banks cannot overlap, eliminating the conflict by design. The conflict guard in `STDP_CTRL_COMPUTE_AND_WRITE_WEIGHTS` is a safety measure only.

8. **Swappable module port interfaces must be treated as immutable contracts.** Any future replacement of `trace_increase_logic.v` or `weight_update_logic.v` must present exactly the ports specified in this document with exactly the same names, widths, and directions. The surrounding modules depend on these interfaces at elaboration time.

9. **`weight_update_logic_bank_array` is wired combinationally inside `stdp_controller`.** Its outputs are valid combinationally whenever its inputs are valid. The STDP controller registers the outputs before driving the write-back to `banked_weight_memory`, ensuring a clean registered write path.

10. **Parameters must be consistently propagated.** Every module that uses a system parameter must declare it as a local parameter with a default value matching the global default, and every instantiation site must explicitly override it using the `#(.PARAM(PARAM))` syntax. No hardcoded numeric constants representing system dimensions should appear anywhere in the RTL.
