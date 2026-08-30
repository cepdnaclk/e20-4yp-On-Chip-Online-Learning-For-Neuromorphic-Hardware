# Attic — parked, not deleted

Nothing here is used by the working system. Nothing here has been deleted
either: every file is still in Git with its full history, just moved out of the
way so the live folders only contain things that actually run.

**To bring anything back**, move it to where you want it:

```bash
git mv attic/placeholder-folders/crossbar code/ip/interconnect/crossbar
```

To just look at something without moving it, open it where it sits.

---

## `placeholder-folders/`

Folders that contained **a README and nothing else**. Each README described
files that were never written, which made the project look much bigger than it
is and made the real code hard to find.

| Parked as | Came from | Why |
|---|---|---|
| `code-build/` | `code/build/` | README only. Described `.vcd`/`.log` build artefacts. The real build folder is `code/ip/03.learning-rule/stdp_engine/build/`, created automatically. |
| `code-global_inc/` | `code/global_inc/` | README only. Described `neuro_defines.vh` and `aer_pkg.sv` — **neither file was ever written**. |
| `code-scripts/` | `code/scripts/` | README only. Described `weight_gen.py` and `spike_monitor.py` — **neither file was ever written**. |
| `code-sw_modeling/` | `code/sw_modeling/` | Contained one empty (0-byte) `ReadME.md`. |
| `izhikevich/` | `code/ip/01.neurons/izhikevich/` | README only. The Izhikevich neuron model was planned, never built. The working neuron is `stdp_engine/rtl/lif_neuron.v`. |
| `crossbar/` | `code/ip/interconnect/crossbar/` | README only. Superseded by `stdp_engine/rtl/spike_router.v`, which is the interconnect that actually runs. |
| `aer_rx_tx/` | `code/ip/interconnect/aer_rx_tx/` | README and an empty Makefile, no RTL. Also superseded by `spike_router.v`. |
| `upload-your-code-here.txt` | `code/` | Leftover from the original repository template. |
| `eons_cpp-readme-1byte.md` | `code/software_simulation/eons_cpp/` | A 1-byte `readme.md` sitting next to the real `README.md`. |

## `stdp-engine-superseded/`

Old versions of the learning engine, from before the 2026-08-25 rewrite.

`files/` holds the previous neuron core, the old testbenches, and scratch
files. Several of them still reference `connection_matrix_inst.connection_table`,
a structure that no longer exists — so they will not compile against today's
RTL without being updated first.

`Makefile-dead-targets.mk` holds five `make` targets that were removed from
`stdp_engine/Makefile`. Each one referenced a file that had already been moved
out of the active tree, so **every one of them failed the moment it was run**:

| Removed target | Needed a file that was already gone |
|---|---|
| `make test_neuron_cluster` | `tb/tb_neuron_cluster.v` |
| `make test_neuron_cluster_v2` | `tb/tb_neuron_cluster_v2.v` (an empty file) |
| `make test_mnist` | `tools/prepare_mnist.py`, `tb/tb_mnist_inference.v` |
| `make test_mnist_debug` | `tb/tb_mnist_inference_debug.v` |
| `make wave_mnist_debug` | the waveform `test_mnist_debug` never produced |

`make test_all` used to depend on `test_neuron_cluster_v2`, which is why
`make test_all` failed before this cleanup. It now runs the seven module tests
that work.

The MNIST download code was rescued out of the retired `prepare_mnist.py` into
`stdp_engine/tools/download_mnist.py`, so `make download_mnist` works again.
