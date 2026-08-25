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

## 4. Many clusters

The design scales past one cluster. `neuron_cluster_array` instantiates
`NUM_CLUSTERS` clusters plus one `spike_router`.

```bash
make multi_cluster                    # 4 clusters x 32 =  128 neurons
make multi_cluster MC_CLUSTERS=32     # 32 clusters x 32 = 1024 neurons
make multi_cluster_all                # sweep 2, 4, 8, 32 clusters
```

### How clusters talk

**Only 1-bit spike events cross a cluster boundary.** Weights, traces and
crossbar state stay entirely inside the cluster that owns the *post-synaptic*
neuron, so nothing has to be shared or kept coherent between clusters. This is
the same partitioning IBM TrueNorth uses: a core owns its axons, its crossbar
and its neurons; the network carries spikes only.

```
cluster k neuron fires
  -> cluster_spike_output_bus[k]
  -> spike_router      (routing table: destination clusters + axon index)
  -> external_spike_input_bus of each destination cluster
  -> that cluster distributes the axon's weight row to its own neurons
     and bumps that axon's pre-synaptic trace
```

`neuron_cluster` itself is **unchanged**. Its existing
`external_spike_input_bus` already behaves exactly as an axon injection port —
an injected address is treated as a pre-synaptic source, so "a remote neuron
fired" is delivered simply by pulsing the axon slot that represents it.
Multi-cluster is a pure wrapper, which is why the single-cluster MNIST path
carries zero risk from it.

### Address map

```
global address = cluster_index * NUM_NEURONS_PER_CLUSTER + local_index
```

Inside a cluster, local addresses are split by convention (nothing is
hardwired — the testbench decides):

| Role | Behaviour |
|---|---|
| **axon** | driven by the router or by external input; acts purely as a pre-synaptic source |
| **neuron** | a real LIF neuron whose spikes leave the cluster through the router |

An axon slot still instantiates a LIF neuron that never fires, because nothing
is wired into it. That costs area but keeps `neuron_cluster` untouched.

### Routing table

Three arrays inside `spike_router`, one entry per global neuron:

```verilog
route_valid             [g]   // 1 = neuron g's spikes go somewhere
route_dest_cluster_mask [g]   // bitmask of destination clusters
route_dest_axon         [g]   // axon index within each destination cluster
```

One entry can fan out to several clusters, but always to the **same axon index**
in each. That keeps the table one word per neuron instead of one word per
(neuron, cluster) pair. The router serialises simultaneous spikes through a
FIFO, one delivery per clock, so nothing is merged or lost.

### What is verified

`tb/tb_multi_cluster.v` builds a feedforward chain
`ext -> C0.axon -> C0.neuron -> C1.axon -> C1.neuron -> ...` and checks:

| # | Check |
|---|---|
| 1 | An injected spike fires cluster 0's neuron |
| 2 | The router carries it across a cluster boundary |
| 3 | The chain propagates through every cluster in order |
| 4 | A cluster with no outgoing route drives nothing |
| 5 | Simultaneous spikes are serialised, not merged |
| 6 | **LTP on a cross-cluster synapse** — a weight in the downstream cluster rises when its routed axon fires just before its neuron |
| 7 | **LTD** — a weight whose axon stayed silent falls |
| 8 | No queue overflow, transaction timeout or router overflow |

Results:

```
 2 clusters x 32 =  64 neurons    13 passed, 0 failed
 4 clusters x 32 = 128 neurons    17 passed, 0 failed
 8 clusters x 32 = 256 neurons    25 passed, 0 failed
32 clusters x 32 = 1024 neurons   73 passed, 0 failed     <- target config
```

The 1024-neuron build elaborates in ~1 s and simulates in ~5 s. Cross-cluster
STDP measured in cluster 1: `W(routed axon -> neuron) 250 -> 255` (LTP),
`W(silent axon -> neuron) 120 -> 113` (LTD).

### Multi-cluster limits

* **Winner-take-all is per cluster.** There is no global WTA across clusters.
* **A routing entry fans out to one axon index**, the same in every destination
  cluster.
* **Fan-in per neuron is bounded by `NUM_NEURONS_PER_CLUSTER`**, because the
  crossbar is that many axons wide. With 32-neuron clusters each neuron sees at
  most 32 sources — the network must be sparse.
* **The MNIST demo is still single-cluster.** `make mnist` targets one
  `neuron_cluster`; it has not been re-partitioned across the array. Mapping
  MNIST onto many clusters means splitting the 100 inputs across cores, which
  is a topology design task, not an RTL one.
* **`tb_multi_cluster` requires `NUM_CLUSTERS >= 2`** — the cross-cluster STDP
  check reads cluster 1.

---

## 5. Topology comparison — measured

Three topologies, all 1200 images (720 train / 240 assign / 240 test),
identical STDP constants, identical seed:

| | Topology | Excitatory | Hidden | Accuracy |
|---|---|---|---|---|
| baseline | 1 cluster x 128 | 28 | 0 | 29.58 % |
| **A wide** | **4 clusters x 128** | **112** | **0** | **41.67 %** |
| B layered | 5 clusters x 64 | 32 out | 32 | 11.25 % |
| — | random chance | — | — | 10.00 % |

```bash
make mnist          MNIST_IMAGES=1200   # baseline, 1 cluster
make mnist_wide     MNIST_IMAGES=1200   # A
make mnist_layered  MNIST_IMAGES=1200   # B
```

### A — wide (4 clusters x 128), 41.67 %

```
per cluster: axons 0..99   = the same 100 pixels
             neurons 100..127 = 28 excitatory, own WTA
-> 112 excitatory neurons, 11,200 plastic synapses, no hidden layer
```

Capacity was the binding constraint, and adding it worked:

| | baseline (28) | A (112) |
|---|---|---|
| Neurons that responded | 23 / 28 | 87 / 112 |
| Digits with at least one neuron | 7 / 10 | **9 / 10** |
| Accuracy | 29.58 % | **41.67 %** |

Per-digit: 0 → 91.7 %, 1 → 74.2 %, 2 → 61.9 %, 3 → 56.5 %, 8 → 45.0 %,
7 → 34.4 %, 9 → 21.7 %, 6 → 19.0 %, 4 → 0 %, 5 → 0 %.

Digit 5 still gets no neuron. Digit 4 is the interesting failure: it *has*
13 assigned neurons but still scores 0 %, meaning those neurons fire on 4s
without firing *more* than the neurons of competing classes — the per-class
mean-rate vote loses. That is a readout weakness, not a synapse weakness.

The router is not used in A: all four clusters receive the same externally
injected pixel spikes, so this is four competing populations rather than one
112-way WTA.

### B — layered (5 clusters x 64), 11.25 %

```
L1: 4 clusters, axons 0..24 = one 5x5 image quadrant, 8 excitatory each
                                                        -> 32 hidden neurons
L2: 1 cluster,  axons 0..31 = one per hidden neuron (via spike_router)
                neurons 32..63 = 32 output neurons
```

This is the only topology with real intermediate neurons, and the only one
that drives the router with a real workload. It works mechanically — 32/32
output neurons respond, no queue overflow, no STDP timeout, no router
overflow, and layer 1 learns clean stroke fragments per quadrant — but it
classifies barely above chance.

**Why B fails: an information bottleneck at layer 1.** WTA lets roughly one
of the 8 neurons in each L1 cluster fire per timestep, so the entire image is
compressed to "which of 8 won, in each of 4 quadrants" — about 12 bits per
timestep. Layer 2 cannot recover what layer 1 discarded, and unsupervised
STDP gives layer 1 no objective tying its features to class discriminability.

Fixing it needs far more hidden neurons per quadrant. With N=64 a cluster has
only 32 neuron slots, and L2 can accept only 32 axons, so 32 hidden is the
ceiling for this shape. A serious attempt needs N=256 (128 axons + 128
neurons per cluster), which costs roughly 8x the simulation time.

**Practical conclusion: on this hardware, spend neurons on width, not depth.**

---

## 6. What you get back

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

## 7. Limitations

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

## 8. If something looks wrong

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
