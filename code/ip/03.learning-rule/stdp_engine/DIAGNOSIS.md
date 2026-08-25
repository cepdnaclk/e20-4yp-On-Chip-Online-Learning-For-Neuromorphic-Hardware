# stdp_engine — diagnosis (2026-08-25)

## Tooling
`iverilog` was not installed and there is no passwordless sudo. Installed locally
without root by extracting the Arch package:

    curl -sL -o iverilog.pkg.tar.zst https://archlinux.org/packages/extra/x86_64/iverilog/download/
    tar --zstd -xf iverilog.pkg.tar.zst -C <dir>
    <dir>/usr/bin/iverilog -B <dir>/usr/lib/ivl ...
    <dir>/usr/bin/vvp     -M <dir>/usr/lib/ivl ...

Permanent fix: `sudo pacman -S iverilog`.

## Confirmed failure
`make test_mnist` prints the banner, loads the hex files, then never emits a
single calibration line. It is **not** a Verilog deadlock — it is dead logic
plus extreme slowness.

## Root causes (verified by cycle-level probe on neuron_cluster)

1. **P0 — connection matrix stale read.** `cluster_connection_matrix` registers
   its read one cycle after the address, but `row_data_valid` is asserted
   unconditionally every non-reset cycle. `stdp_controller` also assigns
   `connection_matrix_read_row_address` inside the state that consumes the
   result. Probe evidence: dequeued neuron 10 (a hidden neuron, whose input
   vector must be empty) produced `pending_trace_result_count = 201`, i.e. it
   used row 0's vector. Consequence: every spike is processed against the
   *wrong* neuron's connectivity, `weight_distribution_bus_valid` never fires
   for the correct target, so **no output neuron ever receives a weight and
   none ever spikes**.

2. **P0 — LIF neuron model unusable.**
   `Simple_LIF_Neuron_Model_Initial.v` + `Internal_neuron_accumulator`:
   - `always @(posedge clock or posedge reset or posedge input_spike_wire)`
     and `always @(posedge spike_input or posedge reset or ...)` — event-driven,
     not clocked; races, not synthesizable.
   - Mixed blocking/non-blocking in the same block.
   - `threshold_reg` grows monotonically (1 -> 3 -> 7 -> 13 ...) and never
     decays, so the neuron goes permanently silent after a few spikes.
     **This is the "stops after the first spike" symptom.**
   - `spike_output_reg` is held high for the whole 297-count window, so
     `spike_input_queue` re-enqueues the same neuron on every clock edge.
   Replacement written: `rtl/lif_neuron.v` (`stdp_lif_neuron`) — synchronous,
   1-cycle spike pulse, refractory period, adaptive threshold that decays.

3. **P0 — no lateral inhibition / no working homeostasis.** With 10 output
   neurons all seeing the same inputs and the same STDP rule, they converge to
   identical weights. Unsupervised STDP MNIST needs WTA + adaptive thresholds
   (Diehl & Cook 2015).

4. **P1 — ~600 cycles of simulation per spike.** `stdp_controller` scans all
   256 column steps per spike regardless of connectivity, and takes 2 cycles
   per pre-synaptic trace fetch. Should iterate only over set bits of the
   connection vectors, 1 cycle each.

5. **P1 — `pre_trace_request_pointer_register` is NEURON_ADDRESS_WIDTH bits.**
   A set bit at index N-1 makes the pointer wrap to 0 and the scan restarts
   forever. Not triggered by the current MNIST layout (max index 209) but a
   latent infinite loop.

6. **P1 — `trace_update_arbiter` result FIFO** double-counts / mis-tracks
   `fifo_entry_count_register` on the empty+push path.

7. **P1 — `spike_input_queue` enqueues on level, not edge.**

8. **P2 — `weight_bank_write_enable_per_bank` is set to all-ones**, writing
   every bank instead of masking to the actually-connected pre-synaptic banks.

## Weight memory layout (confirmed correct)
`W(pre=p, post=t)` lives at `bank_memory[(t+p) mod 256][t]`.
Row read at address `f` returns all *incoming* weights to `f`;
column read with `step=t` returns the weight from `f` to `t`.
`stdp_controller`'s de-skew (`store[(bank - fired + N) & (N-1)]`) matches this.

---

# Fixes applied (2026-08-25)

| # | File | Defect | Fix |
|---|---|---|---|
| 1 | `cluster_connection_matrix.v` | registered read + `row_data_valid` hard-wired high → every transaction used the PREVIOUS neuron's connectivity | combinational read; storage changed to two N-bit row vectors |
| 2 | `stdp_controller.v` | row address assigned in the same state that consumed it | address registered in `IDLE`, consumed in `SETUP` |
| 3 | `lif_neuron.v` (new) | IP neuron: event-driven always blocks, monotonically growing threshold, spike held high 297 cycles | new synchronous LIF: 1-cycle spike pulse, refractory, *decaying* adaptive threshold |
| 4 | `lateral_inhibition.v` (new) | no competition at all → all excitatory neurons learn one identical receptive field | combinational max-membrane WTA arbiter with rotating tie-break |
| 5 | `spike_input_queue.v` | enqueued on spike LEVEL → a held-high spike output re-enqueued every cycle and the cluster never drained | rising-edge detect; push/count bookkeeping rewritten |
| 6 | `trace_update_arbiter.v` | FIFO count double-counted on the empty+push path → trace results lost, controller waited forever | clean head/tail/count FIFO with explicit bypass |
| 7 | `trace_update_module.v` | DECAY_COMPUTE wrote the decayed value back with the ORIGINAL timestamp → the same decay was applied again on every read | re-stamp with the current timer value |
| 8 | `stdp_controller.v` | scanned all N columns and took 2 cycles per pre-synaptic trace | connection vectors flattened to index lists once per transaction; 1 cycle per connected entry |
| 9 | `stdp_controller.v` | `weight_bank_write_enable_per_bank` set to all-ones | masked to actually-connected pre-synaptic banks |
| 10 | `stdp_controller.v` | scan pointer was `NEURON_ADDRESS_WIDTH` bits → a set bit at index N-1 wrapped it to 0 and re-scanned forever | pointers widened to `COUNT_WIDTH` |
| 11 | `neuron_cluster.v` | cluster freeze gated synaptic integration, but weight distribution happens *during* a transaction | freeze now defers only *firing*; integration always runs |
| 12 | `stdp_controller.v` | (introduced during the index-list refactor) pointer advanced by neuron index + 1 instead of list position + 1, so each input spike reached exactly ONE excitatory neuron | advance by list position |
| 13 | `lif_neuron.v` | `fire_request` included `force_inhibit`, which the arbiter derives from `fire_request` → combinational loop, simulator hang | `force_inhibit` removed from the request term |

## Performance work
Simulation cost per image fell from ~24 000 cycles to ~10 500, and wall time
per image from ~5.7 s to ~1.4 s, via:
* index lists instead of two N-iteration combinational set-bit scans per cycle;
* the de-skewed pre-synaptic trace bus registered once per transaction instead
  of re-evaluating N parallel `weight_update_logic` instances on every arriving
  trace result;
* dropping the per-transaction N-entry clear of the trace result store
  (every connected slot is overwritten, unconnected banks are write-masked);
* guarding the N-bank write scan, the N-neuron enqueue scan and the WTA
  arbitration scan so they only run on cycles where they can do anything.

## Verification
All six pre-existing unit-test suites pass unchanged:
`global_decay_timer` 9/9, `trace_memory` 8/8, `banked_weight_memory` 3/3,
`trace_update_module` 8/8, `spike_input_queue` 6/6, `weight_update_logic` 6/6.
(`tb/tb_spike_input_queue.v` needed one added wire because the module gained a
`queue_overflow_flag` port and the testbench connects with `.*`.)

## Known-stale files in this directory
Not touched, but they are dead weight: `test2.v`, `missing.v`, `test_no_always.v`,
`test_results.v`, `stdp_cim_tile.v` (empty), `tb/tb_neuron_cluster_v2.v` (empty),
`stdp_neuron_core_old.v`, all `out*.log`, all top-level `*.vcd`, `a.out`.
`tb/tb_mnist_inference.v` and `tb/tb_neuron_cluster.v` are the legacy
testbenches; they poke `connection_matrix_inst.connection_table`, which no
longer exists after fix #1, so they need updating to the new
`input_connection_rows` / `output_connection_rows` names if they are to be kept.

---

# Follow-on defects found while bringing up learning (2026-08-25)

These were found by measuring, not by inspection, and each one on its own was
enough to stop the network learning anything.

| # | Where | Defect | Evidence | Fix |
|---|---|---|---|---|
| 14 | `stdp_controller.v` | After flattening the connection vectors into index lists, the scan pointers were advanced by *neuron index + 1* instead of *list position + 1*. For the input layer (indices 0..99) index and position coincide, so learning looked fine — but the distribution list starts at neuron 100, so the pointer jumped straight past the end and **each input spike reached exactly ONE excitatory neuron**. | membrane probe: neurons 101..127 sat at 0 forever, only neuron 100 accumulated | advance by list position |
| 15 | `lateral_inhibition.v` / `lif_neuron.v` | WTA inhibited *after* observing a spike. The cluster freezes firing while the queue drains, so every excitatory neuron above threshold fired on the same cycle the freeze lifted; all of them got identical LTP and learned one identical receptive field. | all 28 neurons had bit-identical membrane and theta traces | arbitration made **combinational**: neurons raise `fire_request`, the arbiter grants exactly one (highest membrane), losers are inhibited in the same cycle |
| 16 | `lateral_inhibition.v` | Fixed lowest-index-wins tie-break collapsed the layer onto neuron 100. | only neuron 100 ever spiked | rotating priority origin |
| 17 | `tb_mnist_stdp.v` | **`decay_enable_pulse` was deasserted in the same delta as the clock edge**, racing the DUT's own `@(posedge)`. The global decay timer never incremented once. `delta_t` was permanently 0, so no trace ever decayed, every synapse whose input had *ever* fired kept `pre_trace = 255` and kept receiving LTP, and **all weights saturated at 255**. A neuron with all-255 weights is a generic "any input" detector that wins every image, so the layer had no selectivity at all. | probe printed `timer=0` at every excitatory write; `preTrace>0` climbed 25/100 → 99/100; mean weight 252 | `#1` after each `@(posedge clock)` before deasserting |

Defect 17 is the one that masked everything else: with it present, no amount of
LTP/LTD or homeostasis tuning could have worked. After fixing it the fraction of
potentiated synapses per excitatory spike stays at the correct 12–29 / 100 and
recognisable digit-shaped receptive fields appear in `bank_memory`.

Also added while debugging: `arbiter_idle_flag` on `trace_update_arbiter`, used
by `stdp_controller` to refuse to start a transaction until the trace pipeline
is fully drained, so a transaction can never be credited with a trace result
belonging to the previous one.

## Debugging lesson worth keeping
Every one of these was found by dumping internal state at a specific event
(`state_register == ST_WRITE`, membrane per neuron per timestep, trace memory
contents and `delta_t`) — not by reading the RTL. The `tb_p*.v` probe pattern in
the scratchpad is worth re-creating whenever behaviour looks wrong: flatten
generate-scope internals into a `wire [...] x [0:N-1]` array with a `genvar`
loop so runtime indices work, then print at the event of interest.
