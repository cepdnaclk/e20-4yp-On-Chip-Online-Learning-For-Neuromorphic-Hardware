![SNN Activity Simulation](https://github.com/cepdnaclk/e20-4yp-On-Chip-Online-Learning-For-Neuromorphic-Hardware/blob/main/docs/images/WhatsApp%20Image%202026-02-15%20at%2001.50.39.jpeg)
<b>NOMAD</b> is a specialized hardware accelerator designed to address the "static intelligence" limitation of current edge AI. While traditional accelerators are optimized for inference using pre-trained weights, NOMAD implements On-chip Online Learning using Spiking Neural Networks (SNNs).

By leveraging the biological plausibility of <b>Leaky Integrate-and-Fire (LIF) neurons</b>, the architecture processes information through discrete temporal spikes, significantly reducing power consumption compared to traditional frame-based neural networks. The core innovation lies in its ability to update synaptic weights locally and autonomously while the hardware is operational, eliminating the need for off-chip training data or high-power GPU intervention.
Key Research Focus:

- <b>Architecture:</b> A modular RTL implementation optimized for the Chipyard and Vivado ecosystems.
- <b>On-chip Adaptability:</b> Implementation of local learning rules (such as STDP or hardware-friendly approximations) that allow the system to adapt to non-stationary data in real-time.
- <b>Performance Optimization:</b> Designing data paths that maintain high classification accuracy while adhering to the strict power and area constraints of a low-power neuromorphic accelerator.

This project aims to provide a robust framework for truly autonomous edge devices capable of learning from their environment post-deployment.

---

## Getting started

**New here, or not a hardware person? Read [HOW-TO-RUN.md](HOW-TO-RUN.md).**
It explains in plain English what this is, how to run every experiment with a
single command each, and how to design your own network shape.

```bash
sudo pacman -S iverilog                      # the simulator (only dependency)
cd code/ip/03.learning-rule/stdp_engine
make download_mnist                          # get the handwriting data, once
make mnist_wide                              # the best-performing experiment
```

### Results so far

Unsupervised on-chip STDP, 1200 MNIST images (720 learn / 240 label / 240 test):

| Topology | Neurons | Accuracy |
|---|---|---|
| 1 cluster × 128 | 28 | 29.58 % |
| **4 clusters × 128 (wide)** | **112** | **41.67 %** |
| 5 clusters × 64 (layered, 2 stages) | 32 | 11.25 % |
| 2 clusters × 256 (wide, 14×14 input) | 120 | 32.92 % |
| *random guessing* | — | *10.00 %* |

Width beats depth. Full analysis, including why the layered and higher-resolution
attempts underperformed, is in [HOW-TO-RUN.md](HOW-TO-RUN.md#6-what-we-learned).

### Where things live

| Path | What it is |
|---|---|
| [`HOW-TO-RUN.md`](HOW-TO-RUN.md) | plain-English guide — start here |
| `code/ip/03.learning-rule/stdp_engine/` | the working system: RTL, testbenches, experiments |
| `code/ip/03.learning-rule/stdp_engine/README.md` | technical reference |
| `code/ip/03.learning-rule/stdp_engine/DIAGNOSIS.md` | every bug found during bring-up, with evidence |
| `code/ip/03.learning-rule/stdp_engine/runs/` | every past run, date-stamped, never overwritten |
| `attic/` | parked clutter — nothing here runs, nothing is deleted |
