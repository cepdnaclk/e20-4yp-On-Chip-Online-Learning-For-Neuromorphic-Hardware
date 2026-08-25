#!/usr/bin/env python3
"""
prepare_mnist_stdp.py — data prep for the STDP cluster MNIST demo.

Network layout inside one neuron_cluster of N neurons:

    neuron  0 .. NUM_INPUT-1              input layer  (driven externally,
                                                        Poisson rate coded)
    neuron  EXC_START .. EXC_START+NUM_EXC-1
                                          excitatory layer (WTA + STDP)

Connectivity (all-to-all input -> excitatory):
    input_connection_rows [exc][in] = 1   -> `in` is PRE to `exc`   (LTP/LTD)
    output_connection_rows[in][exc] = 1   -> `in` drives `exc`      (distribution)

Weight storage in banked_weight_memory:
    W(pre=p, post=t)  ->  bank_memory[(t + p) mod N][t]

Outputs (written to --out-dir):
    mnist_spikes.hex   images*timesteps lines, N/4 hex chars each
    mnist_labels.hex   images lines, 1 hex char each
    init_weights.hex   N*2^ADDR_W lines, 2 hex chars each
    mnist_config.vh    Verilog parameter file consumed by the testbench
"""

import argparse
import os
import struct
import sys

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

    grid=14 : straight 2x2 average pool of the full frame.
    grid=10 : crop to the central 20x20 (where MNIST digits live) then 2x2 pool.
    grid=7  : straight 4x4 average pool.
    """
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
    assert size // factor == grid, f"{size}/{factor} != {grid}"
    return crop.reshape(n, grid, factor, grid, factor).mean(axis=(2, 4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="data/mnist")
    ap.add_argument("--out-dir", default="tb")
    ap.add_argument("--split", default="train", choices=["train", "test"])
    ap.add_argument("--images", type=int, default=600)
    ap.add_argument("--timesteps", type=int, default=12)
    ap.add_argument("--grid", type=int, default=10)
    ap.add_argument("--neurons", type=int, default=128)
    ap.add_argument("--num-exc", type=int, default=28)
    ap.add_argument("--max-rate", type=float, default=0.55,
                    help="spike probability of a fully-white pixel per timestep")
    ap.add_argument("--init-weight-min", type=int, default=40)
    ap.add_argument("--init-weight-max", type=int, default=90)
    ap.add_argument("--base-threshold", type=int, default=6000)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)

    num_input = args.grid * args.grid
    num_neurons = args.neurons
    exc_start = num_neurons - args.num_exc
    if num_input > exc_start:
        raise SystemExit(
            f"{num_input} inputs + {args.num_exc} excitatory > {num_neurons} neurons")

    addr_width = int(np.ceil(np.log2(num_neurons)))
    bank_depth = 1 << addr_width

    # ---- load ----
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

    # ---- downsample + normalise ----
    small = downsample(images, args.grid).reshape(args.images, num_input) / 255.0
    rates = np.clip(small, 0.0, 1.0) * args.max_rate

    # ---- Poisson (Bernoulli per timestep) rate coding ----
    os.makedirs(args.out_dir, exist_ok=True)
    hex_chars = num_neurons // 4

    total_spikes = 0
    with open(os.path.join(args.out_dir, "mnist_spikes.hex"), "w") as f:
        for i in range(args.images):
            draws = rng.random((args.timesteps, num_input)) < rates[i]
            total_spikes += int(draws.sum())
            for t in range(args.timesteps):
                word = 0
                for p in np.nonzero(draws[t])[0]:
                    word |= 1 << int(p)
                f.write(f"{word:0{hex_chars}x}\n")

    with open(os.path.join(args.out_dir, "mnist_labels.hex"), "w") as f:
        for lb in labels:
            f.write(f"{int(lb):x}\n")

    # ---- initial weights ----
    flat = np.zeros(num_neurons * bank_depth, dtype=np.uint8)
    for e in range(exc_start, exc_start + args.num_exc):
        for p in range(num_input):
            bank = (e + p) % num_neurons
            flat[bank * bank_depth + e] = rng.integers(
                args.init_weight_min, args.init_weight_max + 1)
    with open(os.path.join(args.out_dir, "init_weights.hex"), "w") as f:
        f.write("\n".join(f"{v:02x}" for v in flat) + "\n")

    # ---- Verilog config ----
    with open(os.path.join(args.out_dir, "mnist_config.vh"), "w") as f:
        f.write(f"""// AUTO-GENERATED by tools/prepare_mnist_stdp.py — do not edit.
localparam NUM_NEURONS_PER_CLUSTER = {num_neurons};
localparam NEURON_ADDRESS_WIDTH    = {addr_width};
localparam BANK_DEPTH              = {bank_depth};
localparam NUM_INPUT               = {num_input};
localparam GRID                    = {args.grid};
localparam NUM_EXC                 = {args.num_exc};
localparam EXC_START               = {exc_start};
localparam EXC_END                 = {exc_start + args.num_exc - 1};
localparam N_IMAGES                = {args.images};
localparam TIMESTEPS_PER_IMG       = {args.timesteps};
localparam BASE_THRESHOLD          = {args.base_threshold};
""")

    avg = total_spikes / (args.images * args.timesteps)
    print(f"  images            : {args.images} ({args.split} split)")
    print(f"  grid              : {args.grid}x{args.grid} = {num_input} input neurons")
    print(f"  excitatory        : {args.num_exc}  (neurons {exc_start}..{exc_start+args.num_exc-1})")
    print(f"  cluster neurons   : {num_neurons}  (addr width {addr_width})")
    print(f"  timesteps/image   : {args.timesteps}")
    print(f"  mean input spikes : {avg:.1f} per timestep")
    print(f"  init weights      : U[{args.init_weight_min}, {args.init_weight_max}]")
    print(f"  base threshold    : {args.base_threshold}")
    print(f"  expected drive    : ~{avg * (args.init_weight_min+args.init_weight_max)/2:.0f} per timestep")
    print(f"  wrote {args.out_dir}/mnist_spikes.hex, mnist_labels.hex, "
          f"init_weights.hex, mnist_config.vh")


if __name__ == "__main__":
    main()
