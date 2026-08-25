# STDP Engine — On-Chip Unsupervised Learning Cluster

A single-cluster spiking neural network accelerator in Verilog that learns MNIST
digits **on chip** with pair-based STDP, then classifies unseen digits. No
backpropagation, no host-side training — the weights live in the RTL's banked
SRAM and are updated by the hardware itself as spikes arrive.

```
make mnist          # prepare data, build, train, infer, print accuracy
```

---

## 1. What the machine is

One `neuron_cluster` of N neurons. Neurons are addressed 0..N-1 and any neuron
can be pre-synaptic, post-synaptic, or both — the `cluster_connection_matrix`
decides. For the MNIST demo the cluster is partitioned:

```
N = 128 neurons

  neuron   0 ..  99   INPUT layer       10x10 downsampled MNIST,
                                        Poisson rate-coded, driven from
                                        external_spike_input_bus
  neuron 100 .. 127   EXCITATORY layer  28 neurons, winner-take-all,
                                        weights trained by STDP
```

Connectivity is all-to-all input→excitatory (2 800 plastic synapses):

| Table entry | Meaning | Consumed when |
|---|---|---|
| `input_connection_rows[e][i] = 1` | `i` is PRE-synaptic to `e` | `e` fires → LTP/LTD on W(i→e) |
| `output_connection_rows[i][e] = 1` | `i` drives `e` | `i` fires → W(i→e) sent to `e` |

---

## 2. Where the weights live

All synaptic weights are 8-bit unsigned, held in `banked_weight_memory` as
N independent SRAM banks:

```
W(pre = p, post = t)   lives at   bank_memory[(t + p) mod N][t]
```

This skewed layout is what makes both access patterns single-cycle:

* **Row read** at address `f` returns `bank_memory[b][f]` for *every* bank at
  once — i.e. all **incoming** weights of neuron `f`, one per bank. This is the
  learning path: one read gives the whole weight vector to update.
* **Column read** with `step = t` returns the single weight from the fired
  neuron `f` to target `t`. This is the inference path: one weight per cycle
  onto the distribution bus.

`stdp_controller` de-skews bank order back to neuron order with
`store[(bank - f) mod N]` before applying the update.

Traces live separately in `trace_memory`: one 21-bit entry per neuron
`{saturated_flag, timestamp[11:0], value[7:0]}`, async read, sync write.

---

## 3. How a spike flows

Everything is driven by one **transaction per spiking neuron**, serialised by
`spike_input_queue`.

```
external_spike_input_bus ─┐
                          ├─► spike_input_queue ─► stdp_controller
neuron spike outputs ─────┘        (one address per transaction)
```

`stdp_controller` FSM: `IDLE → SETUP → SCAN → WAIT → WRITE`

| State | What happens |
|---|---|
| `IDLE`  | accept a queued address `f`, present it to the connection matrix and trace memory |
| `SETUP` | latch `f`'s connectivity, flatten both vectors into index lists, issue INCREASE on trace[f], issue the row read of all incoming weights |
| `SCAN`  | **A)** one column read per connected output → weight distribution bus. **B)** one pre-synaptic trace read + DECAY_COMPUTE per connected input. Both run in parallel, one entry per cycle |
| `WAIT`  | block until every trace result has returned and the row read landed |
| `WRITE` | write all updated weights back in one cycle, masked to connected banks |

### Inference path (A)
`column read → weight_distribution_bus → weight_distribution_receiver[t] →
stdp_lif_neuron[t].input_spike`. The receiver emits a one-cycle pulse carrying
the weight; the LIF neuron integrates it into its membrane.

### Learning path (B)
`trace_memory[i] → trace_update_arbiter → trace_update_module (DECAY_COMPUTE)`
gives the *effective* pre-synaptic trace now. Traces use **lazy decay**: a trace
stores `(value, timestamp)` and its present value is `value >> (now - timestamp)`,
computed only when read. `weight_update_logic_bank_array` then applies, per bank,
in parallel:

```
pre_trace > 0   →  LTP :  w += pre_trace  >> LTP_SHIFT_AMOUNT    (max +31)
pre_trace == 0  →  LTD :  w -= post_trace >> LTD_SHIFT_AMOUNT    (max -15)
```

The pre-synaptic trace halves on every decay tick, and the testbench issues
`DECAY_TICKS_PER_STEP = 4` ticks per timestep. That sets the STDP causal window:
a pre-spike is worth +31 in its own timestep, +1 one timestep later, and nothing
after — so only inputs that fired *just before* the post-synaptic spike are
potentiated. Everything else is depressed. That difference is the learning.

---

## 4. Why there is a winner-take-all

Every excitatory neuron sees the same inputs and the same STDP rule, so without
competition they all converge on one identical receptive field and the layer
cannot discriminate anything.

`lateral_inhibition_wta` arbitrates **combinationally, in the same cycle a
neuron would fire**: neurons raise `fire_request` at threshold, and exactly one
grant is issued — to the requester with the **highest membrane potential**, i.e.
the neuron whose learned weights best match the current input. Every other
requester is inhibited (membrane wiped, forced refractory). Ties are broken by a
priority origin that rotates after each grant, so no fixed index bias can
collapse the layer onto one neuron.

Arbitration *must* be combinational: the cluster freezes firing while the spike
queue drains, so many neurons sit above threshold at once and would otherwise
all fire on the cycle the freeze lifts.

`stdp_lif_neuron` also carries an **adaptive threshold** (`theta`): +`THETA_INCREMENT`
on every spike, decaying by `theta >> THETA_DECAY_SHIFT` per tick. This is the
homeostasis that stops a strong neuron monopolising the layer and forces the
rest to specialise. It keeps running during inference — only *weight* learning
is frozen there.

---

## 5. Training and classification

Three phases, all in `tb/tb_mnist_stdp.v`:

1. **TRAIN** — `learning_enable = 1`. Purely unsupervised: labels are never
   shown to the hardware. STDP + WTA + homeostasis shape the receptive fields.
2. **ASSIGN** — `learning_enable = 0`. Each excitatory neuron is labelled with
   the digit that produces its highest *mean* response.
3. **TEST** — predict `argmax` over per-class mean firing rate of the neurons
   assigned to each class.

The testbench prints overall accuracy, per-digit accuracy, a confusion matrix,
and dumps learned receptive fields as ASCII art read straight back out of
`bank_memory`.

---

## 6. Measured results

`make mnist MNIST_IMAGES=1200` (720 train / 240 assign / 240 test, 28 excitatory
neurons, 10x10 input, 20 timesteps per image), Icarus Verilog 13.0:

```
  Test images        : 240
  Correct            : 71
  ACCURACY           : 29.58 %
  Random baseline    : 10.00 %

  digit 0 :  23 /  24   (95.8%)      digit 5 :   4 /  16   (25.0%)
  digit 1 :  20 /  31   (64.5%)      digit 6 :   0 /  21   ( 0.0%)
  digit 2 :   0 /  21   ( 0.0%)      digit 7 :  11 /  32   (34.4%)
  digit 3 :   1 /  23   ( 4.3%)      digit 8 :  10 /  20   (50.0%)
  digit 4 :   2 /  29   ( 6.9%)      digit 9 :   0 /  23   ( 0.0%)

  23 / 28 neurons responded
  neurons per digit: 0:4  1:5  2:0  3:3  4:4  5:2  6:0  7:3  8:2  9:0
  drain timeouts=0  queue overflow=0  stdp timeout=0
```

Learned receptive fields, read straight back out of `bank_memory` after
training — these are the actual 8-bit weights, not a simulation of them:

```
    neuron 102  (label 1)          neuron 101  (label 7)
                                                 '
                  ####++                         ####'
                  ####                       ##########
                ####                         ##    ##
              ..##..                       ++..' ++##
              ####                         ##..####'
            ' ####                         ..####..'
            ####                           ######'
          ####                           ..####
          ####                           ##
```

Runtime: ~1.4 s per image (~10 500 simulated cycles per image), so the run
above takes about 35 minutes.

### Reading these numbers
Learning clearly works: digits 0, 1, 8 and 7 are recognised well and the
receptive fields are digit-shaped. The ceiling is **class coverage** — with 28
excitatory neurons, digits 2, 6 and 9 ended up with no assigned neuron at all
and therefore score 0 %, which alone caps accuracy near 70 %.

The two levers that matter most, in order:

1. **More excitatory neurons.** 28 is thin for 10 classes. Diehl & Cook (2015),
   the algorithm this implements, uses 100 neurons for ~82 % and 400 for ~87 %.
   Going past 28 needs a 256-neuron cluster
   (`MNIST_NEURONS=256 MNIST_NUM_EXC=100`, `MNIST_GRID=14` for 196 inputs),
   which is roughly 4x the simulation cost per image.
2. **More training images.** 720 is very few — accuracy rose from 17.5 % at 120
   training images to 29.6 % at 720 with everything else identical.

Both cost only simulation time; no RTL changes are required.

---

## 7. Running it

```bash
make mnist                          # full pipeline, default 600 images
make mnist MNIST_IMAGES=1500        # more data, better accuracy, longer sim
make mnist_prepare                  # regenerate hex files only
make mnist_build                    # compile only
make mnist_run                      # re-run without recompiling
```

Split is 60 % train / 20 % assign / 20 % test.

Useful knobs (all `make` variables): `MNIST_IMAGES`, `MNIST_TIMESTEPS`,
`MNIST_GRID` (7/10/14), `MNIST_NEURONS`, `MNIST_NUM_EXC`, `MNIST_THRESHOLD`,
`MNIST_MAX_RATE`, `MNIST_SEED`. STDP/neuron constants
(`LTP_SHIFT_AMOUNT`, `LTD_SHIFT_AMOUNT`, `THETA_INCREMENT`,
`DECAY_TICKS_PER_STEP`, …) are parameters at the top of `tb/tb_mnist_stdp.v`.

**Prerequisite:** `iverilog`. On Arch: `sudo pacman -S iverilog`.
MNIST IDX files are expected in `data/mnist/` (`make download_mnist` fetches them).

### Diagnostics
The cluster exposes `queue_overflow_flag` and `transaction_timeout_flag`, and
the testbench reports drain timeouts. All three should be 0 / clean; a non-zero
value means the pipeline stalled rather than merely performing poorly.

---

## 8. Module map

| File | Role |
|---|---|
| `rtl/neuron_cluster.v` | top level: wires everything together |
| `rtl/stdp_controller.v` | the transaction FSM — the heart of the design |
| `rtl/banked_weight_memory.v` | N-bank weight SRAM, row/column/masked-write ports |
| `rtl/cluster_connection_matrix.v` | who is connected to whom (combinational read) |
| `rtl/trace_memory.v` | one lazy-decay trace entry per neuron |
| `rtl/trace_update_module.v` | INCREASE / DECAY_COMPUTE, 2-cycle latency |
| `rtl/trace_update_arbiter.v` | pool of trace units + tagged result FIFO |
| `rtl/weight_update_logic.v` | the STDP rule itself (swappable) |
| `rtl/weight_update_logic_bank_array.v` | N parallel copies, one per bank |
| `rtl/lif_neuron.v` | LIF neuron: leak, refractory, adaptive threshold |
| `rtl/lateral_inhibition.v` | combinational max-membrane WTA arbiter |
| `rtl/spike_input_queue.v` | edge-triggered spike FIFO + cluster freeze |
| `rtl/global_decay_timer.v` | global tick counter for lazy trace decay |
| `tools/prepare_mnist_stdp.py` | rate-codes MNIST, emits hex + `mnist_config.vh` |
| `tb/tb_mnist_stdp.v` | train / assign / test harness and reporting |

`DIAGNOSIS.md` records the defects found in the original design and why each
mattered.
