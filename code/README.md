# What's in `code/`

This is a map of what is actually here. To *run* anything, see
[HOW-TO-RUN.md](../HOW-TO-RUN.md) in the project root.

```text
code/
├── ip/
│   ├── 01.neurons/
│   │   ├── lif_standard/            early standalone neuron experiments
│   │   └── lif_standard_weighted/   ← the version the engine still compiles in
│   │
│   ├── 02.encoding/
│   │   └── spike_encoder/           turns pixel values into spike trains
│   │
│   └── 03.learning-rule/
│       └── stdp_engine/             ★ THE WORKING SYSTEM — everything runs here
│
├── verification/                    Python cross-checks for the encoder
│
└── software_simulation/
    └── eons_cpp/                    separate C++ NOMAD-EONS study, not part
                                     of the hardware flow
```

**Nearly all the live work is in `ip/03.learning-rule/stdp_engine/`.** That
folder holds the complete self-learning design — neurons, learning rule,
memory, the multi-cluster router, and all four MNIST experiments. Its own
`README.md` is the technical reference; `DIAGNOSIS.md` records every bug found
during bring-up.

The earlier folders are kept because they are real history: the neuron in
`01.neurons/lif_standard_weighted/rtl/` is still referenced by the engine's
Makefile, and `02.encoding/` documents how pixels become spikes.

A previous version of this file described a much larger planned structure
(`plasticity/`, `r_stdp/`, `global_inc/`, `scripts/`) that was never built. It
is kept at `attic/placeholder-folders/code-README-planned-structure.md`.
