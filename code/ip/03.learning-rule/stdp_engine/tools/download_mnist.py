#!/usr/bin/env python3
"""Download the four MNIST IDX files used by every experiment.

    python3 tools/download_mnist.py --data-dir data/mnist

Files already present are skipped, so it is safe to run more than once.
Extracted from the retired tools/prepare_mnist.py (now in attic/) so that
`make download_mnist` does not depend on a superseded script.
"""

import argparse
import gzip
import os
import shutil
import urllib.request

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


def download_mnist(data_dir: str) -> None:
    os.makedirs(data_dir, exist_ok=True)
    for key, url in MNIST_URLS.items():
        dest = os.path.join(data_dir, MNIST_FILENAMES[key])
        if os.path.exists(dest):
            print(f"  [skip] {MNIST_FILENAMES[key]} already exists")
            continue
        print(f"  Downloading {MNIST_FILENAMES[key]} ...", end="", flush=True)
        gz = dest + ".gz"
        urllib.request.urlretrieve(url, gz)
        with gzip.open(gz, "rb") as src, open(dest, "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.remove(gz)
        print(" done")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="data/mnist")
    download_mnist(ap.parse_args().data_dir)
