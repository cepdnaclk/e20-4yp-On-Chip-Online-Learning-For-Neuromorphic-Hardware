# STDP Engine — On-Chip Learning Neuromorphic Accelerator

A spiking neural network in Verilog that **learns MNIST digits in the hardware
itself** using STDP. No backpropagation, no training on a PC — the weights live
in the RTL's SRAM and are updated by the chip as spikes arrive.

```bash
sudo pacman -S iverilog     # the only dependency
make download_mnist         # fetch the MNIST data (once)
make mnist                  # prepare data -> build -> train -> classify -> accuracy
```

> Not a hardware person? Read [`HOW-TO-RUN.md`](../../../../HOW-TO-RUN.md) in
> the project root — same material, plain English, no jargon.

---

## 1. The sizes, and how to change them

Everything about the network's shape is set **on the command line**. You never
edit RTL and you never edit a testbench.

```bash
make mnist_wide MNIST_IMAGES=1200 MNIST_GRID=10 MNIST_CLUSTERS=4 MNIST_NEURONS=128
```

The prepare step writes `tb/mnist_config*.vh`, the testbench `` `include ``s it,
and address widths, bank counts, WTA ranges and the connection matrix all
follow automatically.

| Variable | Default | What it changes |
|---|---|---|
| `MNIST_IMAGES` | 1200 | total pictures, split 60 % train / 20 % assign / 20 % test |
| `MNIST_GRID` | 10 | image resolution: 7, 10 or 14 → 49, 100 or 196 inputs |
| `MNIST_NEURONS` | 128 | slots per cluster — **must be a power of 2** |
| `MNIST_CLUSTERS` | 4 | how many clusters (wide topology) |
| `MNIST_TIMESTEPS` | 20 | how long each picture is shown |
| `MNIST_THRESHOLD` | 1500 | how easily a neuron fires |
| `MNIST_MAX_RATE` | 0.55 | firing rate of a fully-white pixel |
| `MNIST_SEED` | 1 | randomness for encoding and initial weights |

### The one rule that governs everything

**Inside a cluster, inputs and neurons share the same pockets.**

```
inputs + neurons  ≤  MNIST_NEURONS        (and MNIST_NEURONS is a power of 2)
inputs = MNIST_GRID x MNIST_GRID
```

So a 128-pocket cluster holding 100 inputs has 28 pockets left for neurons.
Want more neurons? Either add clusters, or move to a bigger cluster.

| Resolution | Inputs | Cluster size | Neurons left | Simulation cost |
|---|---|---|---|---|
| 7×7 | 49 | 64 | 15 | very fast |
| 10×10 | 100 | 128 | 28 | ~35 min / 1200 images / cluster |
| 14×14 | 196 | 256 | 60 | ~4× slower |
| 28×28 (full MNIST) | 784 | 1024 | 240 | fits, but weeks in simulation |

Full-resolution MNIST **fits the design** — 784 + 240 = 1024. It is only
simulation speed that stops us running it; on a real FPGA or chip it is fine.

The script refuses invalid shapes rather than building something broken:

```
196 inputs + 50 excitatory > 128 neurons
```

Learning-rule constants (`LTP_SHIFT_AMOUNT`, `LTD_SHIFT_AMOUNT`,
`THETA_INCREMENT`, `DECAY_TICKS_PER_STEP`, `WTA_INHIBIT_CYCLES`) are parameters
at the top of the testbench in `tb/`. Those you edit by hand.

---

## 2. Commands

| Command | What it does |
|---|---|
| `make mnist` | single cluster, 100 inputs, 28 neurons — the baseline |
| `make mnist_wide` | **best result** — 4 clusters, 112 neurons |
| `make mnist_layered` | two layers with real hidden neurons |
| `make multi_cluster` | directed multi-cluster hardware test (4 clusters) |
| `make multi_cluster MC_CLUSTERS=32` | same test at 32 clusters = 1024 neurons |
| `make multi_cluster_all` | sweep 2, 4, 8, 32 clusters |
| `make test_all` | per-module unit tests |
| `make download_mnist` | fetch the MNIST data files |
| `make clean` | remove build artefacts |

Split each `make mnist*` into stages if you want:
`make mnist_prepare` (data only), `make mnist_build` (compile only),
`make mnist_run` (re-run without recompiling).

Every full run is archived automatically — see §5.

---

## 3. Results so far

All 1200 images, identical learning constants and seed:

| Topology | Inputs | Hidden | Output neurons | Accuracy |
|---|---|---|---|---|
| 1 cluster × 128 | 100 | 0 | 28 | 29.58 % |
| **4 clusters × 128 (wide)** | **100** | **0** | **112** | **41.67 %** |
| 5 clusters × 64 (layered) | 100 | 32 | 32 | 11.25 % |
| 2 clusters × 256 (wide, 14×14) | 196 | 0 | 120 | 32.92 % |
| random guessing | — | — | — | 10.00 % |

**Width beats depth on this hardware.** Going from 28 to 112 neurons lifted the
digits that had at least one neuron assigned from 7/10 to 9/10, and responding
neurons from 23/28 to 87/112.

The 14×14 wide run is **undertrained, not resolution-limited**: 14 543 training
spikes against 38 084 for the 10×10 wide run — about 121 learning events per
neuron instead of 340. Only 51 of 120 neurons ever responded, mean weight
stalled at 60, and the receptive fields came back nearly blank. It was given
2.4× the input dimensionality and a third of the practice. Retry with more
images and `MNIST_TIMESTEPS=20`.

Digits **4 and 5 score 0 % in every wide run**. In the 10×10 wide run digit 5
was assigned no neuron at all, making it structurally unpredictable; digit 4
had 13 neurons assigned and still scored 0/29. Digit coverage improved across
the runs (7/10 → 9/10 → 10/10 digits assigned) while accuracy peaked in the
middle. This is the most promising thing to fix next.

The layered version is the only one with real hidden neurons and the only one
that uses the inter-cluster router for a real workload. It runs correctly —
no overflow, no timeouts, and layer 1 learns clean stroke fragments — but
classifies near chance, because winner-take-all at layer 1 squeezes the whole
image down to about 12 bits per timestep and layer 2 cannot recover the loss.

---

## 4. How it is arranged

### The wide topology (the one that works best)

Four **identical copies**, not one network cut into pieces. Every cluster sees
the same 100 inputs and forms its own opinion with its own 28 neurons. At the
end all 112 neurons vote. Like four people looking at the same photo and
voting, rather than four people each seeing a quarter of it.

```
per cluster:  pockets   0..99   = the 100 image inputs (same in every cluster)
              pockets 100..127  = 28 neurons, competing with each other
```

### Inside one cluster

```
spike -> spike_input_queue -> stdp_controller
                                |- column reads -> distribution bus -> neurons   (RECOGNISING)
                                |- trace reads  -> weight update    -> SRAM      (LEARNING)
```

Weights are stored as `W(from, to)` at `bank_memory[(to + from) mod N][to]`.
That layout lets the chip read *all* of a neuron's incoming weights in one go
(for learning) and one outgoing weight per cycle (for recognising).

### Between clusters

Only 1-bit spike events cross a cluster boundary — never weights. A routing
table says which cluster(s) and which input pocket each neuron's spike goes to.
Tested up to 32 clusters × 32 neurons = 1024 neurons.

### Neuron types

There is **one** neuron module, `rtl/lif_neuron.v`. Input pockets and output
neurons are the same hardware; the difference is only what is wired to them.
There are **no inhibitory neurons** — competition is done by an arbiter
(`rtl/lateral_inhibition.v`), and weights are unsigned so nothing is negative.

---

## 5. Run history

Every run is archived under `runs/` with a date and time stamp:

```
runs/2026-08-25_104444_mnist_wide/
    INFO.txt    date, git commit, duration, headline accuracy
    run.log     complete simulation output
    *.vh        the exact configuration that run used
```

Nothing is overwritten, so you can always go back and compare. To archive a run
by hand:

```bash
tools/run_and_archive.sh <name> build/<file>.vvp tb/mnist_config.vh
```

---

## 6. Reading the output

```
ACCURACY : 41.67 %      100 of 240 test images
Health   : queue overflow=0  stdp timeout=0  router overflow=0
```

The health line must be all zeros. Anything else means the pipeline stalled —
a real fault, not just a poor score.

| Symptom | Meaning |
|---|---|
| `excitatory spikes: 0` | nothing fired — lower `MNIST_THRESHOLD` or raise `MNIST_MAX_RATE` |
| `drain timeouts > 0` | a transaction never finished |
| `queue overflow = 1` | too many spikes at once |
| receptive fields all `####` | weights saturated — learning is unbalanced |
| receptive fields unchanged | those neurons never won the competition |

---

## 7. Files

| Path | What it is |
|---|---|
| `rtl/` | the hardware |
| `tb/` | testbenches |
| `tools/` | data preparation and the run archiver |
| `runs/` | every past run, timestamped |
| `data/mnist/` | MNIST source data |
| `DIAGNOSIS.md` | every defect found in the original design, with evidence |
| `../../../../attic/` | superseded files and removed Makefile targets, kept for reference |

Key modules: `neuron_cluster.v` (one cluster), `stdp_controller.v` (the FSM that
does the work), `banked_weight_memory.v` (the weights), `lif_neuron.v` (the
neuron), `lateral_inhibition.v` (the competition), `spike_router.v` and
`neuron_cluster_array.v` (many clusters).
