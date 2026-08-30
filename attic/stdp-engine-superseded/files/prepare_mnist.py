#!/usr/bin/env python3
# =============================================================================
# prepare_mnist.py
# Prepares MNIST data for the SNN accelerator testbench.
#
# What it does:
#   1. Loads MNIST IDX files from --data-dir  (or downloads them with --download)
#   2. Rate-encodes each image through a fixed random 784→200 projection to
#      produce sparse spike patterns for the 200 hidden neurons (neurons 10–209).
#   3. Writes three hex files that Verilog $readmemh can consume directly.
#
# Output files (written to --output-dir, default: tb/):
#   mnist_spikes.hex   N_IMAGES × TIMESTEPS lines; each line = 64 hex chars (256-bit
#                      spike bus: only bits [209:10] can be set, one per hidden neuron)
#   mnist_labels.hex   N_IMAGES lines; each line = 1 hex char (digit 0–9)
#   init_weights.hex   256×256 = 65536 lines; each line = 2 hex chars
#                      (flat dump of bank_memory[bank][addr], row-major)
#
# Cluster layout (must match tb_mnist_inference.v parameters):
#   Neurons   0–9  : output layer  (one per digit class)
#   Neurons 10–209 : hidden layer  (200 neurons, driven by external spike bus)
#   Neurons 210–255: unused
#
# Weight bank formula: W[post][pre] → Bank = (post+pre) % 256, Addr = post
# Only hidden→output entries (output ∈ 0–9, hidden ∈ 10–209) are non-zero.
# =============================================================================

import argparse
import gzip
import os
import shutil
import struct
import sys
import urllib.request

import numpy as np

# ── Cluster constants (must match testbench parameters) ──────────────────────
NUM_CLUSTER_NEURONS = 256
OUTPUT_START = 0
OUTPUT_END = 9
HIDDEN_START = 10
HIDDEN_END = 209
NUM_OUTPUT = 10
NUM_HIDDEN = 200
NUM_INPUT_PIXELS = 784  # 28 × 28
NUM_WEIGHT_BANKS = 256
WEIGHT_BANK_DEPTH = 256  # 2^WEIGHT_BANK_ADDRESS_WIDTH

# ── MNIST file metadata ───────────────────────────────────────────────────────
MNIST_URLS = {
    "train-images": "https://ossci-datasets.s3.amazonaws.com/mnist/train-images-idx3-ubyte.gz",
    "train-labels": "https://ossci-datasets.s3.amazonaws.com/mnist/train-labels-idx1-ubyte.gz",
    "test-images": "https://ossci-datasets.s3.amazonaws.com/mnist/t10k-images-idx3-ubyte.gz",
    "test-labels": "https://ossci-datasets.s3.amazonaws.com/mnist/t10k-labels-idx1-ubyte.gz",
}
MNIST_FILENAMES = {
    "train-images": "train-images-idx3-ubyte",
    "train-labels": "train-labels-idx1-ubyte",
    "test-images": "t10k-images-idx3-ubyte",
    "test-labels": "t10k-labels-idx1-ubyte",
}


# =============================================================================
# MNIST I/O
# =============================================================================


def download_mnist(data_dir: str) -> None:
    os.makedirs(data_dir, exist_ok=True)
    for key, url in MNIST_URLS.items():
        dest = os.path.join(data_dir, MNIST_FILENAMES[key])
        if os.path.exists(dest):
            print(f"  [skip] {MNIST_FILENAMES[key]} already exists")
            continue
        print(f"  Downloading {MNIST_FILENAMES[key]} …", end="", flush=True)
        gz = dest + ".gz"
        urllib.request.urlretrieve(url, gz)
        with gzip.open(gz, "rb") as src, open(dest, "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.remove(gz)
        print(" done")


def load_images(path: str) -> np.ndarray:
    """Returns float32 array of shape (N, 784), values in [0, 255]."""
    with open(path, "rb") as f:
        magic, n, rows, cols = struct.unpack(">IIII", f.read(16))
        assert magic == 2051, f"Expected magic 2051, got {magic}"
        data = np.frombuffer(f.read(), dtype=np.uint8)
    return data.reshape(n, rows * cols).astype(np.float32)


def load_labels(path: str) -> np.ndarray:
    """Returns uint8 array of shape (N,)."""
    with open(path, "rb") as f:
        magic, n = struct.unpack(">II", f.read(8))
        assert magic == 2049, f"Expected magic 2049, got {magic}"
        return np.frombuffer(f.read(), dtype=np.uint8)


# =============================================================================
# Spike encoding
# =============================================================================


def build_projection(rng: np.random.Generator) -> np.ndarray:
    """
    Returns a fixed random projection matrix of shape (784, 200).
    Each column is L2-normalised so all hidden neurons receive comparable total input.
    """
    W = rng.standard_normal((NUM_INPUT_PIXELS, NUM_HIDDEN)).astype(np.float32)
    norms = np.linalg.norm(W, axis=0, keepdims=True)
    norms[norms == 0] = 1.0
    return W / norms


def encode_images(
    images: np.ndarray,
    labels: np.ndarray,
    T: int,
    top_k: int,
    rng: np.random.Generator,
    projection: np.ndarray,
) -> tuple[list[list[int]], np.ndarray]:
    """
    Rate-encode N images into sparse spike patterns.

    Strategy per timestep per image:
      1. Compute hidden activation = projection(pixel) → shape (200,)
      2. Normalise activations to [0, 1].
      3. Use activation as Bernoulli spike probability.
      4. From the fired neurons, keep only the top-K most activated.
         (guarantees sparsity ≤ K spikes/timestep regardless of threshold)

    Returns:
      patterns : list of N lists, each containing T integers (256-bit spike buses)
      labels   : unchanged labels array (for convenience)
    """
    N = len(images)
    norm_images = images / 255.0  # (N, 784)  → [0, 1]
    activations = norm_images @ projection  # (N, 200)

    # Normalise per-image activations to [0, 0.9] to avoid saturation
    img_max = activations.max(axis=1, keepdims=True)
    img_max[img_max == 0] = 1.0
    probs = activations / img_max * 0.9  # (N, 200)

    patterns: list[list[int]] = []

    for i in range(N):
        img_pattern: list[int] = []
        p = probs[i]  # (200,) probabilities

        for _ in range(T):
            # Bernoulli draw
            fired = rng.random(NUM_HIDDEN) < p

            # Keep only top-K among fired (enforce sparsity)
            fired_indices = np.where(fired)[0]
            if len(fired_indices) > top_k:
                # Pick top-K by activation strength
                strengths = p[fired_indices]
                keep = fired_indices[np.argsort(strengths)[-top_k:]]
                fired = np.zeros(NUM_HIDDEN, dtype=bool)
                fired[keep] = True

            # Pack into 256-bit integer: bit position = neuron index
            spike_int = 0
            for h_local, did_fire in enumerate(fired):
                if did_fire:
                    neuron_idx = HIDDEN_START + h_local
                    spike_int |= 1 << neuron_idx

            img_pattern.append(spike_int)

        patterns.append(img_pattern)

        if (i + 1) % 100 == 0 or i == N - 1:
            avg_k = sum(bin(v).count("1") for v in img_pattern) / T
            print(
                f"  Encoded {i + 1:>4d}/{N}  avg spikes/timestep: {avg_k:.2f}",
                flush=True,
            )

    return patterns, labels


# =============================================================================
# Weight initialisation
# =============================================================================


def build_init_weights(initial_value: int = 200) -> np.ndarray:
    """
    Returns a (256, 256) uint8 array representing bank_memory[bank][addr].

    Only hidden→output synapses are set to initial_value.
    For W[post][pre]:  bank = (post+pre) % 256,  addr = post

    post ∈ {0..9}  (output neurons)
    pre  ∈ {10..209} (hidden neurons)

    Each (post, pre) pair maps to a unique (bank, addr) slot — no collisions.
    (Proof: two pairs share a slot iff same bank AND same addr; same addr ⟹
    same post; same bank ⟹ same (post+pre)%256 ⟹ same pre. So uniqueness holds.)
    """
    bank_mem = np.zeros((NUM_WEIGHT_BANKS, WEIGHT_BANK_DEPTH), dtype=np.uint8)

    for post in range(OUTPUT_START, OUTPUT_END + 1):
        for pre in range(HIDDEN_START, HIDDEN_END + 1):
            bank = (post + pre) % NUM_WEIGHT_BANKS
            addr = post
            bank_mem[bank][addr] = initial_value

    non_zero = int((bank_mem > 0).sum())
    print(
        f"  Non-zero weight entries: {non_zero}  (expected {NUM_OUTPUT * NUM_HIDDEN})"
    )
    return bank_mem


# =============================================================================
# Hex file writers
# =============================================================================


def write_spikes_hex(patterns: list[list[int]], T: int, path: str) -> None:
    N = len(patterns)
    print(f"  Writing {path}  ({N * T} lines) …", end="", flush=True)
    with open(path, "w") as f:
        for img_pats in patterns:
            for val in img_pats:
                f.write(f"{val:064x}\n")
    print(" done")


def write_labels_hex(labels: np.ndarray, path: str) -> None:
    print(f"  Writing {path}  ({len(labels)} lines) …", end="", flush=True)
    with open(path, "w") as f:
        for lbl in labels:
            f.write(f"{int(lbl):01x}\n")
    print(" done")


def write_weights_hex(bank_mem: np.ndarray, path: str) -> None:
    rows = NUM_WEIGHT_BANKS * WEIGHT_BANK_DEPTH
    print(f"  Writing {path}  ({rows} lines) …", end="", flush=True)
    with open(path, "w") as f:
        for bank in range(NUM_WEIGHT_BANKS):
            for addr in range(WEIGHT_BANK_DEPTH):
                f.write(f"{bank_mem[bank][addr]:02x}\n")
    print(" done")


# =============================================================================
# Entry point
# =============================================================================


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Prepare MNIST spike patterns for the SNN accelerator testbench."
    )
    parser.add_argument(
        "--images",
        type=int,
        default=200,
        help="Number of images to process (default: 200)",
    )
    parser.add_argument(
        "--timesteps",
        type=int,
        default=20,
        help="Spike timesteps per image (default: 20)",
    )
    parser.add_argument(
        "--top-k",
        type=int,
        default=3,
        help="Max hidden neuron spikes per timestep (default: 3)",
    )
    parser.add_argument(
        "--init-weight",
        type=int,
        default=200,
        help="Initial hidden→output weight value 0–255 (default: 200)",
    )
    parser.add_argument(
        "--seed", type=int, default=42, help="Random seed (default: 42)"
    )
    parser.add_argument(
        "--split",
        choices=["train", "test"],
        default="test",
        help="MNIST split to use (default: test)",
    )
    parser.add_argument(
        "--data-dir",
        type=str,
        default="data/mnist",
        help="Directory containing MNIST IDX files",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default="tb",
        help="Directory to write hex files into (default: tb)",
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="Download MNIST IDX files into --data-dir if missing",
    )
    args = parser.parse_args()

    print("=" * 62)
    print("  MNIST SNN Accelerator Preprocessor")
    print(
        f"  images={args.images}  timesteps={args.timesteps}  "
        f"top_k={args.top_k}  init_weight={args.init_weight}"
    )
    print(f"  split={args.split}  seed={args.seed}")
    print(f"  data_dir={args.data_dir}  output_dir={args.output_dir}")
    print("=" * 62)

    # ── Download ────────────────────────────────────────────────────────────
    if args.download:
        print("Downloading MNIST …")
        download_mnist(args.data_dir)

    # ── Load ────────────────────────────────────────────────────────────────
    key_prefix = args.split  # "train" or "test"
    img_path = os.path.join(args.data_dir, MNIST_FILENAMES[f"{key_prefix}-images"])
    lbl_path = os.path.join(args.data_dir, MNIST_FILENAMES[f"{key_prefix}-labels"])

    if not os.path.exists(img_path):
        sys.exit(
            f"ERROR: {img_path} not found.\n"
            f"Place MNIST IDX files in {args.data_dir}/ or run with --download.\n"
            f"Files needed:\n" + "\n".join(f"  {v}" for v in MNIST_FILENAMES.values())
        )

    print("Loading MNIST …")
    images = load_images(img_path)
    labels = load_labels(lbl_path)

    N = min(args.images, len(images))
    images = images[:N]
    labels = labels[:N]
    unique, counts = np.unique(labels, return_counts=True)
    print(
        f"  Loaded {N} images. Class distribution: "
        + "  ".join(f"{u}:{c}" for u, c in zip(unique, counts))
    )

    # ── Encode ──────────────────────────────────────────────────────────────
    rng = np.random.default_rng(args.seed)
    print("Building projection matrix …")
    projection = build_projection(rng)

    print("Encoding images to spike patterns …")
    patterns, labels_out = encode_images(
        images, labels, args.timesteps, args.top_k, rng, projection
    )

    # Sparsity report
    total_spikes = sum(bin(v).count("1") for img_p in patterns for v in img_p)
    avg_spikes = total_spikes / (N * args.timesteps)
    print(
        f"  Overall avg spikes/timestep: {avg_spikes:.3f} / {NUM_HIDDEN} hidden neurons"
    )

    # ── Write hex files ──────────────────────────────────────────────────────
    os.makedirs(args.output_dir, exist_ok=True)
    print("Writing hex files …")
    write_spikes_hex(
        patterns, args.timesteps, os.path.join(args.output_dir, "mnist_spikes.hex")
    )
    write_labels_hex(labels_out, os.path.join(args.output_dir, "mnist_labels.hex"))

    print("Building initial weight table …")
    bank_mem = build_init_weights(args.init_weight)
    write_weights_hex(bank_mem, os.path.join(args.output_dir, "init_weights.hex"))

    print()
    print("Files written to", args.output_dir)
    print(f"  mnist_spikes.hex   — {N} images × {args.timesteps} timesteps")
    print(f"  mnist_labels.hex   — {N} labels")
    print(
        f"  init_weights.hex   — {NUM_WEIGHT_BANKS}×{WEIGHT_BANK_DEPTH} weight entries"
    )
    print()
    print("Next step:  make test_mnist")
    print("            make test_mnist MNIST_IMAGES=500 MNIST_TIMESTEPS=30")


if __name__ == "__main__":
    main()
