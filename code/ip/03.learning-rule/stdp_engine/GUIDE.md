# STDP Engine — Run Guide & Architecture

Everything you need to run the accelerator yourself, what is actually inside it,
what config produced the published accuracy, and where the walls are.

---

## 1. Run it

```bash
sudo pacman -S iverilog          # one-time; nothing else to install
cd code/ip/03.learning-rule/stdp_engine
make mnist                       # prepare data -> build -> train -> infer -> accuracy
```

That is the whole flow. `make mnist` does three things in order:

| Step | Target | What it does |
|---|---|---|
| 1 | `mnist_prepare` | `tools/prepare_mnist_stdp.py` rate-codes MNIST into spike hex files **and writes `tb/mnist_config.vh`** |
| 2 | `mnist_build`   | `iverilog` compiles the RTL + testbench |
| 3 | `mnist_run`     | `vvp` runs train → assign → test and prints the results |

Sub-targets if you want them separately:

```bash
make mnist_prepare    # regenerate data only
make mnist_build      # compile only
make mnist_run        # re-run the existing build (no recompile)
```

MNIST IDX files must be in `data/mnist/`. They are already there; `make download_mnist`
re-fetches them if needed.

### The exact command that produced 29.58 %

```bash
make mnist MNIST_IMAGES=1200
```

Everything else was left at its default. That is 128 neurons, 28 of them
excitatory, 10×10 input, 20 timesteps per image, base threshold 1500.
It takes **about 35 minutes** and is fully deterministic — same seed, same
numbers every time. Full output is saved in `results_mnist_1200.log`.

---

## 2. Architecture at a glance

| Quantity | Value | Notes |
|---|---|---|
| **Clusters** | **1** | multi-cluster is *not* implemented — see Limitations |
| **Neurons per cluster** | **128** | `NUM_NEURONS_PER_CLUSTER` |
| **Neurons in the whole design** | **128** | one cluster, so same number |
| ├─ input neurons | 100 | addresses 0–99, driven externally (10×10 MNIST) |
| ├─ excitatory neurons | 28 | addresses 100–127, WTA group, STDP-trained |
| └─ unused | 0 | 100 + 28 = 128 exactly |
| **Weight banks** | **128** | one bank per neuron, `NUM_WEIGHT_BANKS = N` |
| **Depth per bank** | 128 entries | `2^NEURON_ADDRESS_WIDTH` |
| **Total weight memory** | 128 × 128 × 8 bit = **16 KB** | `banked_weight_memory` |
| **Plastic synapses actually used** | 100 × 28 = **2 800** | input → excitatory, all-to-all |
| **Trace memory** | 128 entries × 21 bit | one per neuron |
| **Trace update units** | 4 | shared pool behind an arbiter |
| **Spike queue depth** | 128 | one entry per neuron |

Every neuron is addressable as both pre- and post-synaptic. The input/excitatory
split is **not hardwired** — it is purely what `cluster_connection_matrix` is
programmed with. The same RTL supports any wiring pattern.

### Where the weights live

```
W(pre = p, post = t)   →   bank_memory[(t + p) mod N][t]
```

That skew is what makes both access patterns single-cycle:
* **row read** at address `f` → every *incoming* weight of neuron `f`, one per bank (learning)
* **column read** step `t` → the single weight from `f` to `t` (inference)

### One spike = one transaction

```
spike → spike_input_queue → stdp_controller
                              ├── column reads → distribution bus → neuron membranes   (INFERENCE)
                              └── trace reads  → weight_update_logic → bank writes      (LEARNING)
```

FSM: `IDLE → SETUP → SCAN → WAIT → WRITE`.
Cost per transaction: ~1 cycle per connected target, so ~35 cycles for an input
spike (28 targets) and ~110 for an excitatory spike (100 pre-synaptic traces).
Roughly **10 500 simulated cycles per image**, ~1.4 s of wall clock.

---

## 3. Does it scale automatically?

**Yes — you pass the sizes on the `make` command line and everything follows.**
You do not edit RTL and you do not edit the testbench.

```bash
make mnist MNIST_NEURONS=256 MNIST_NUM_EXC=50 MNIST_GRID=14 MNIST_IMAGES=1200
```

The Python step writes `tb/mnist_config.vh`, which the testbench `` `include ``s,
and everything downstream is parameterised from it:

```verilog
localparam NUM_NEURONS_PER_CLUSTER = 256;
localparam NEURON_ADDRESS_WIDTH    = 8;    // derived: log2(N)
localparam BANK_DEPTH              = 256;  // derived: 2^addr_width
localparam NUM_INPUT               = 196;  // derived: GRID*GRID
localparam NUM_EXC                 = 50;
localparam EXC_START               = 206;  // derived: N - NUM_EXC
localparam EXC_END                 = 255;
```

Address widths, bank count, bank depth, the WTA group range, the connection
matrix programming loop, the weight-init file and the spike hex width all follow
automatically. **Verified: 64, 128 and 256-neuron clusters all prepare and
compile cleanly with no manual edits.**

### All the knobs

| Variable | Default | Meaning |
|---|---|---|
| `MNIST_IMAGES` | 600 | total images, split 60 % train / 20 % assign / 20 % test |
| `MNIST_NEURONS` | 128 | neurons per cluster — **must be a power of 2** |
| `MNIST_NUM_EXC` | 28 | excitatory (output) neurons |
| `MNIST_GRID` | 10 | input resolution: 7, 10 or 14 → 49, 100 or 196 inputs |
| `MNIST_TIMESTEPS` | 20 | timesteps per image |
| `MNIST_THRESHOLD` | 1200 | LIF base firing threshold |
| `MNIST_MAX_RATE` | 0.55 | spike probability of a fully-white pixel |
| `MNIST_SEED` | 1 | RNG seed for encoding + weight init |

Two rules the script enforces for you:
1. `MNIST_NEURONS` must be a power of two (bank indexing uses `& (N-1)`).
2. `GRID² + MNIST_NUM_EXC ≤ MNIST_NEURONS`, otherwise it stops with
   `196 inputs + 50 excitatory > 128 neurons`.

Learning-rule constants (`LTP_SHIFT_AMOUNT`, `LTD_SHIFT_AMOUNT`,
`THETA_INCREMENT`, `DECAY_TICKS_PER_STEP`, `WTA_INHIBIT_CYCLES`, …) are
parameters at the top of `tb/tb_mnist_stdp.v` — those you edit by hand.

---

## 4. What you get back

```
ACCURACY : 29.58 %   (71/240)        random baseline 10.00 %

digit 0: 95.8%   digit 3:  4.3%   digit 6:  0.0%   digit 9: 0.0%
digit 1: 64.5%   digit 4:  6.9%   digit 7: 34.4%
digit 2:  0.0%   digit 5: 25.0%   digit 8: 50.0%

23 / 28 neurons responded
neurons per digit: 0:4  1:5  2:0  3:3  4:4  5:2  6:0  7:3  8:2  9:0
drain timeouts=0  queue overflow=0  stdp timeout=0
```

plus a confusion matrix and the learned receptive fields printed as ASCII,
read straight back out of `bank_memory`:

```
neuron 102 (label 1)      neuron 101 (label 7)
        ####++                    ####'
        ####                  ##########
      ####                    ##    ##
    ..##..                  ++..' ++##
    ####                    ##..####'
  ' ####                    ..####..'
  ####                      ######'
####                      ..####
```

**Health line:** `drain timeouts`, `queue overflow` and `stdp timeout` must all
be 0. Non-zero means the pipeline stalled — a real bug, not just poor accuracy.

---

## 5. Limitations

### Hard limits (RTL changes required)

| Limit | Value | Why |
|---|---|---|
| **Clusters** | **1** | `tb_mnist_stdp.v` instantiates a single `neuron_cluster`. There is no inter-cluster spike router, no cluster addressing, no multi-cluster connection matrix. Multi-cluster is unimplemented, not just unconfigured. |
| **Neurons per cluster** | power of 2 only | bank index uses `& (NUM_WEIGHT_BANKS-1)` |
| **Weight width** | 8-bit unsigned | no inhibitory (negative) synapses anywhere |
| **Input resolution** | 7/10/14 only | `downsample()` supports those three pooling factors |

### Practical limit: simulation speed, not the hardware

The RTL scales fine. Icarus does not. Cost grows roughly with N² (N neurons ×
N banks), and the transaction cost grows with the number of connected targets:

| Cluster size | Layout | ≈ time / image | 1200 images |
|---|---|---|---|
| 64 | 49 in + 15 exc | ~0.4 s | ~8 min |
| **128** | **100 in + 28 exc** | **~1.4 s** | **~35 min** |
| 256 | 196 in + 50 exc | ~5 s | ~1.7 h |
| 256 | 196 in + 100 exc | ~8 s | ~2.7 h |

On real FPGA/ASIC hardware none of this applies — it is a simulator limit.

### What is actually capping accuracy at 29.58 %

**Class coverage.** With 28 excitatory neurons, digits 2, 6 and 9 ended up with
*no assigned neuron at all*, so they score 0 % by construction. That alone caps
the achievable score near 70 %. This is not a bug — 28 neurons is simply thin
for 10 classes.

Two levers, in order of impact, **neither needing RTL changes**:

1. **More excitatory neurons.** This implements Diehl & Cook (2015), which uses
   100 neurons for ~82 % and 400 for ~87 %. Going above 28 needs a bigger
   cluster:
   ```bash
   make mnist MNIST_NEURONS=256 MNIST_NUM_EXC=100 MNIST_GRID=14 MNIST_IMAGES=1200
   ```
   Expect ~2.7 h of simulation.

2. **More training images.** Accuracy went **17.5 % → 29.6 %** purely from
   raising training images from 120 to 720, everything else identical. 720 is
   still very few; Diehl & Cook train on 60 000.

### Other honest caveats

* **Unsupervised only.** Labels never reach the hardware. They are used solely
  to *name* neurons after training, and to score the test set.
* **No weight normalisation.** Diehl & Cook keep each neuron's total incoming
  weight constant. That is not implemented; the adaptive threshold (`theta`)
  substitutes for it, less effectively.
* **Homeostasis stays on during inference.** Freezing `theta` at test time let
  whichever neuron ended training with a low threshold monopolise the layer, so
  only *weight* learning is frozen.
* **The legacy testbenches are stale.** `tb/tb_mnist_inference.v` and
  `tb/tb_neuron_cluster.v` poke `connection_matrix_inst.connection_table`, which
  no longer exists. Use `tb/tb_mnist_stdp.v`.
* **The neuron IP is bypassed.** `neuron_cluster` uses `rtl/lif_neuron.v`, not
  `01.neurons/lif_standard_weighted`. The original is unmodified but unusable
  here — see `DIAGNOSIS.md`.

---

## 6. If something looks wrong

| Symptom | Meaning |
|---|---|
| `total excitatory spikes: 0` | nothing fired — lower `MNIST_THRESHOLD` or raise `MNIST_MAX_RATE` |
| `drain timeouts` > 0 | a transaction never completed — pipeline bug |
| `queue overflow=1` | more simultaneous spikes than `SPIKE_QUEUE_DEPTH` |
| `stdp timeout=1` | controller watchdog fired; FSM stalled |
| receptive fields all `####` | weights saturated — LTP too strong vs LTD, or traces are not decaying |
| receptive fields unchanged from init | those neurons never won the WTA |

Related docs: `README.md` (architecture in depth), `DIAGNOSIS.md` (every defect
found in the original design, with the evidence).
