#!/usr/bin/env python3
"""
prepare_mnist_wide.py — data prep for the WIDE multi-cluster topology.

TOPOLOGY A
----------
    NUM_CLUSTERS clusters x 128 neurons

    Uniform local address map in EVERY cluster:
        local   0..99   axons  = the 100 image pixels (SAME input to all clusters)
        local 100..127  neurons = 28 excitatory, WTA within the cluster

    One plastic layer, no hidden neurons -- but NUM_CLUSTERS x 28 output
    neurons instead of 28. This attacks the measured bottleneck of the
    single-cluster run: with only 28 neurons, three digits ended up with no
    assigned neuron at all and scored 0 %.

    Each cluster runs its own independent WTA, so the layer behaves as an
    ensemble of NUM_CLUSTERS competing populations rather than one large WTA.
    The router is not used: every cluster receives the same externally injected
    pixel spikes.

Outputs (to --out-dir):
    mnist_spikes.hex       N_IMAGES*T lines, TOTAL_NEURONS/4 hex chars
    mnist_labels.hex       N_IMAGES lines
    mnist_config_wide.vh   Verilog parameters
"""

import argparse
import os
import struct

import numpy as np


def load_images(path):
    with open(path, "rb") as f:
        magic, n, rows, cols = struct.unpack(">IIII", f.read(16))
        assert magic == 2051, f"bad magic {magic} in {path}"
        data = np.frombuffer(f.read(), dtype=np.uint8)
    return data.reshape(n, rows, cols).astype(np.float32)


def load_labels(path):
    with open(path, "rb") as f:
        magic, n = struct.unpack(">II", f.read(8))
        assert magic == 2049, f"bad magic {magic} in {path}"
        return np.frombuffer(f.read(), dtype=np.uint8)


def downsample(images, grid):
    """28x28 -> grid x grid.
       grid=14 : 2x2 pool of the full frame
       grid=10 : central 20x20 crop then 2x2 pool
       grid=7  : 4x4 pool of the full frame"""
    n = images.shape[0]
    if grid == 14:
        crop, factor = images, 2
    elif grid == 10:
        crop, factor = images[:, 4:24, 4:24], 2
    elif grid == 7:
        crop, factor = images, 4
    else:
        raise SystemExit(f"--grid must be 7, 10 or 14 (got {grid})")
    size = crop.shape[1]
    return crop.reshape(n, grid, factor, grid, factor).mean(axis=(2, 4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="data/mnist")
    ap.add_argument("--out-dir", default="tb")
    ap.add_argument("--split", default="train", choices=["train", "test"])
    ap.add_argument("--images", type=int, default=900)
    ap.add_argument("--timesteps", type=int, default=20)
    ap.add_argument("--max-rate", type=float, default=0.55)
    ap.add_argument("--base-threshold", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--grid", type=int, default=10, choices=[7, 10, 14])
    ap.add_argument("--num-clusters", type=int, default=4)
    ap.add_argument("--neurons-per-cluster", type=int, default=128)
    args = ap.parse_args()

    GRID = args.grid
    NUM_INPUT = GRID * GRID
    N = args.neurons_per_cluster
    NUM_CLUSTERS = args.num_clusters
    TOTAL = NUM_CLUSTERS * N

    AXON_BASE = 0
    NEURON_BASE = NUM_INPUT
    NUM_EXC = N - NEURON_BASE

    if NUM_EXC < 1:
        raise SystemExit(
            f"{NUM_INPUT} inputs leaves no room for neurons in a {N}-slot cluster; "
            f"raise --neurons-per-cluster to {1 << (NUM_INPUT).bit_length()}")
    if N & (N - 1):
        raise SystemExit(f"--neurons-per-cluster must be a power of 2 (got {N})")

    rng = np.random.default_rng(args.seed)

    if args.split == "train":
        img_file, lbl_file = "train-images-idx3-ubyte", "train-labels-idx1-ubyte"
    else:
        img_file, lbl_file = "t10k-images-idx3-ubyte", "t10k-labels-idx1-ubyte"
    img_path = os.path.join(args.data_dir, img_file)
    lbl_path = os.path.join(args.data_dir, lbl_file)
    for p in (img_path, lbl_path):
        if not os.path.exists(p):
            raise SystemExit(f"missing {p}")

    images = load_images(img_path)[: args.images]
    labels = load_labels(lbl_path)[: args.images]
    if len(images) < args.images:
        raise SystemExit(f"only {len(images)} images available")

    small = downsample(images, GRID).reshape(args.images, NUM_INPUT) / 255.0
    rates = np.clip(small, 0.0, 1.0) * args.max_rate

    os.makedirs(args.out_dir, exist_ok=True)
    hex_chars = TOTAL // 4
    total_spikes = 0

    with open(os.path.join(args.out_dir, "mnist_spikes.hex"), "w") as f:
        for i in range(args.images):
            draws = rng.random((args.timesteps, NUM_INPUT)) < rates[i]
            total_spikes += int(draws.sum())
            for t in range(args.timesteps):
                word = 0
                for p in np.nonzero(draws[t])[0]:
                    # replicate the same pixel into every cluster's axon p
                    for c in range(NUM_CLUSTERS):
                        word |= 1 << (c * N + AXON_BASE + int(p))
                f.write(f"{word:0{hex_chars}x}\n")

    with open(os.path.join(args.out_dir, "mnist_labels.hex"), "w") as f:
        for lb in labels:
            f.write(f"{int(lb):x}\n")

    with open(os.path.join(args.out_dir, "mnist_config_wide.vh"), "w") as f:
        f.write(f"""// AUTO-GENERATED by tools/prepare_mnist_wide.py — do not edit.
localparam NUM_CLUSTERS            = {NUM_CLUSTERS};
localparam NUM_NEURONS_PER_CLUSTER = {N};
localparam TOTAL_NEURONS           = {TOTAL};
localparam GRID                    = {GRID};
localparam NUM_INPUT               = {NUM_INPUT};
localparam AXON_BASE               = {AXON_BASE};
localparam NEURON_BASE             = {NEURON_BASE};
localparam NUM_EXC                 = {NUM_EXC};
localparam TOTAL_EXC               = {NUM_CLUSTERS * NUM_EXC};
localparam N_IMAGES                = {args.images};
localparam TIMESTEPS_PER_IMG       = {args.timesteps};
localparam BASE_THRESHOLD          = {args.base_threshold};
""")

    avg = total_spikes / (args.images * args.timesteps)
    print(f"  topology          : {NUM_CLUSTERS} clusters x {N} = {TOTAL} slots")
    print(f"  resolution        : {GRID}x{GRID} = {NUM_INPUT} inputs")
    print(f"  per cluster       : {NUM_INPUT} axons (replicated) + {NUM_EXC} excitatory, WTA")
    print(f"  excitatory total  : {NUM_CLUSTERS*NUM_EXC}  (vs 28 single-cluster)")
    print(f"  plastic synapses  : {NUM_CLUSTERS*NUM_INPUT*NUM_EXC}")
    print(f"  images            : {args.images} ({args.split})")
    print(f"  mean input spikes : {avg:.1f} per timestep (per cluster)")
    print(f"  base threshold    : {args.base_threshold}")
    print(f"  wrote {args.out_dir}/mnist_spikes.hex, mnist_labels.hex, mnist_config_wide.vh")


if __name__ == "__main__":
    main()
