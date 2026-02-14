![SNN Activity Simulation](https://github.com/cepdnaclk/e20-4yp-On-Chip-Online-Learning-For-Neuromorphic-Hardware/blob/main/docs/images/WhatsApp%20Image%202026-02-15%20at%2001.50.39.jpeg)
<b>NOMAD</b> is a specialized hardware accelerator designed to address the "static intelligence" limitation of current edge AI. While traditional accelerators are optimized for inference using pre-trained weights, NOMAD implements On-chip Online Learning using Spiking Neural Networks (SNNs).

By leveraging the biological plausibility of <b>Leaky Integrate-and-Fire (LIF) neurons</b>, the architecture processes information through discrete temporal spikes, significantly reducing power consumption compared to traditional frame-based neural networks. The core innovation lies in its ability to update synaptic weights locally and autonomously while the hardware is operational, eliminating the need for off-chip training data or high-power GPU intervention.
Key Research Focus:

- <b>Architecture:</b> A modular RTL implementation optimized for the Chipyard and Vivado ecosystems.
- <b>On-chip Adaptability:</b> Implementation of local learning rules (such as STDP or hardware-friendly approximations) that allow the system to adapt to non-stationary data in real-time.
- <b>Performance Optimization:</b> Designing data paths that maintain high classification accuracy while adhering to the strict power and area constraints of a low-power neuromorphic accelerator.

This project aims to provide a robust framework for truly autonomous edge devices capable of learning from their environment post-deployment.
