#!/usr/bin/env python3
"""
prepare_mnist_layered.py — data prep for the two-layer multi-cluster topology.

TOPOLOGY B
----------
    5 clusters x 64 neurons

    Uniform local address map in EVERY cluster (WTA_GROUP and BASE_THRESHOLD
    are array-wide parameters, so both layers must share one map):

        local  0..31   axons
        local 32..63   neurons, WTA group

    Layer 1 : clusters 0..3
              axons  0..24 = one 5x5 quadrant of the 10x10 image
              neurons 32..39 = 8 excitatory   -> 32 hidden neurons total
    Layer 2 : cluster 4
              axons  0..31 = one per layer-1 hidden neuron (via spike_router)
              neurons 32..63 = 32 output neurons

Pixel -> (cluster, axon) mapping for a 10x10 image, pixel p = r*10 + c:

        quadrant = (r // 5) * 2 + (c // 5)          -> cluster 0..3
        axon     = (r %  5) * 5 + (c %  5)          -> 0..24

Outputs (to --out-dir):
    mnist_spikes.hex          N_IMAGES*T lines, TOTAL_NEURONS/4 hex chars
                              (flat array bus: {cluster 4 ... cluster 0})
    mnist_labels.hex          N_IMAGES lines, 1 hex char
    mnist_config_layered.vh   Verilog parameters consumed by the testbench

Weights are initialised inside the testbench with $random, so there is no
weight hex file; the run stays deterministic through --seed and the TB seed.
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


def downsample_10(images):
    """28x28 -> central 20x20 crop -> 2x2 average pool -> 10x10."""
    crop = images[:, 4:24, 4:24]
    n = crop.shape[0]
    return crop.reshape(n, 10, 2, 10, 2).mean(axis=(2, 4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="data/mnist")
    ap.add_argument("--out-dir", default="tb")
    ap.add_argument("--split", default="train", choices=["train", "test"])
    ap.add_argument("--images", type=int, default=1200)
    ap.add_argument("--timesteps", type=int, default=20)
    ap.add_argument("--max-rate", type=float, default=0.55)
    ap.add_argument("--base-threshold", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)

    # topology (defaults describe architecture B)
    ap.add_argument("--num-clusters", type=int, default=5)
    ap.add_argument("--neurons-per-cluster", type=int, default=64)
    ap.add_argument("--l1-clusters", type=int, default=4)
    ap.add_argument("--l1-neurons", type=int, default=8)
    args = ap.parse_args()

    GRID = 10
    N = args.neurons_per_cluster
    NUM_CLUSTERS = args.num_clusters
    TOTAL = NUM_CLUSTERS * N

    AXON_BASE = 0
    NEURON_BASE = N // 2            # 32
    NUM_AXONS = N // 2              # 32 axon slots
    NUM_LOCAL_NEURONS = N - NEURON_BASE   # 32 neuron slots

    L1_CLUSTERS = args.l1_clusters
    L2_CLUSTER = L1_CLUSTERS        # cluster index 4
    L1_AXONS = (GRID // 2) ** 2     # 25 pixels per quadrant
    L1_NEURONS = args.l1_neurons    # 8 per L1 cluster
    L2_AXONS = L1_CLUSTERS * L1_NEURONS       # 32
    L2_NEURONS = NUM_LOCAL_NEURONS            # 32

    if L1_AXONS > NUM_AXONS:
        raise SystemExit(f"{L1_AXONS} pixels per quadrant > {NUM_AXONS} axon slots")
    if L2_AXONS > NUM_AXONS:
        raise SystemExit(f"{L2_AXONS} hidden neurons > {NUM_AXONS} axon slots in L2")
    if L1_NEURONS > NUM_LOCAL_NEURONS:
        raise SystemExit(f"{L1_NEURONS} > {NUM_LOCAL_NEURONS} neuron slots")
    if NUM_CLUSTERS != L1_CLUSTERS + 1:
        raise SystemExit("this topology expects exactly one layer-2 cluster")

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

    small = downsample_10(images) / 255.0            # (n, 10, 10)
    rates = np.clip(small, 0.0, 1.0) * args.max_rate

    # pixel (r,c) -> flat array-bus bit index
    bit_of = np.zeros((GRID, GRID), dtype=np.int64)
    for r in range(GRID):
        for c in range(GRID):
            quadrant = (r // 5) * 2 + (c // 5)
            axon = (r % 5) * 5 + (c % 5)
            bit_of[r, c] = quadrant * N + AXON_BASE + axon

    os.makedirs(args.out_dir, exist_ok=True)
    hex_chars = TOTAL // 4
    total_spikes = 0

    with open(os.path.join(args.out_dir, "mnist_spikes.hex"), "w") as f:
        for i in range(args.images):
            draws = rng.random((args.timesteps, GRID, GRID)) < rates[i]
            total_spikes += int(draws.sum())
            for t in range(args.timesteps):
                word = 0
                rr, cc = np.nonzero(draws[t])
                for r, c in zip(rr, cc):
                    word |= 1 << int(bit_of[r, c])
                f.write(f"{word:0{hex_chars}x}\n")

    with open(os.path.join(args.out_dir, "mnist_labels.hex"), "w") as f:
        for lb in labels:
            f.write(f"{int(lb):x}\n")

    with open(os.path.join(args.out_dir, "mnist_config_layered.vh"), "w") as f:
        f.write(f"""// AUTO-GENERATED by tools/prepare_mnist_layered.py — do not edit.
localparam NUM_CLUSTERS            = {NUM_CLUSTERS};
localparam NUM_NEURONS_PER_CLUSTER = {N};
localparam TOTAL_NEURONS           = {TOTAL};
localparam GRID                    = {GRID};

localparam AXON_BASE               = {AXON_BASE};
localparam NUM_AXONS               = {NUM_AXONS};
localparam NEURON_BASE             = {NEURON_BASE};
localparam NUM_LOCAL_NEURONS       = {NUM_LOCAL_NEURONS};

localparam L1_CLUSTERS             = {L1_CLUSTERS};
localparam L1_AXONS                = {L1_AXONS};
localparam L1_NEURONS              = {L1_NEURONS};
localparam L2_CLUSTER              = {L2_CLUSTER};
localparam L2_AXONS                = {L2_AXONS};
localparam L2_NEURONS              = {L2_NEURONS};

localparam N_IMAGES                = {args.images};
localparam TIMESTEPS_PER_IMG       = {args.timesteps};
localparam BASE_THRESHOLD          = {args.base_threshold};
""")

    avg = total_spikes / (args.images * args.timesteps)
    print(f"  topology          : {NUM_CLUSTERS} clusters x {N} neurons "
          f"= {TOTAL} neuron slots")
    print(f"  layer 1           : {L1_CLUSTERS} clusters, {L1_AXONS} axons "
          f"(5x5 quadrant) + {L1_NEURONS} neurons each "
          f"-> {L1_CLUSTERS*L1_NEURONS} hidden")
    print(f"  layer 2           : cluster {L2_CLUSTER}, {L2_AXONS} axons + "
          f"{L2_NEURONS} output neurons")
    print(f"  plastic synapses  : "
          f"{L1_CLUSTERS*L1_AXONS*L1_NEURONS + L2_AXONS*L2_NEURONS}")
    print(f"  images            : {args.images} ({args.split})")
    print(f"  timesteps/image   : {args.timesteps}")
    print(f"  mean input spikes : {avg:.1f} per timestep "
          f"({avg/L1_CLUSTERS:.1f} per L1 cluster)")
    print(f"  base threshold    : {args.base_threshold}")
    print(f"  wrote {args.out_dir}/mnist_spikes.hex, mnist_labels.hex, "
          f"mnist_config_layered.vh")


if __name__ == "__main__":
    main()
