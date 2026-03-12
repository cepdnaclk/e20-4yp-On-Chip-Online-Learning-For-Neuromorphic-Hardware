# NOMAD-EONS Changes Done

This document tracks recent modifications made to the NOMAD-EONS SNN accelerator codebase and parameters.

## Date: 2026-03-12
**Branch**: `MNIST_implementation`

Based on performance analysis and to significantly improve the true classification accuracy of the evolved SNNs on the MNIST dataset, the following permanent hyperparameter modifications were made directly to the `sim/mnist_main.cpp` code:

### Hyperparameter Modifications

1. **Cycles per Sample**
   * **Old Value**: 30
   * **New Value**: 100
   * **Reasoning**: This gives the neurons significantly more simulation time to accumulate membrane potential and fire continuous spike trains. The output decoders will now have a much cleaner "most spikes" distinction over random noise.

2. **Pixel Stride**
   * **Old Value**: 4 (7x7 resolution, 49 input neurons)
   * **New Value**: 1 (28x28 resolution, 784 input neurons)
   * **Reasoning**: Downsampling the digit into a tiny 7x7 grid removes all critical structural features needed to distinguish digits (like 8, 3, 4, 9). Providing the network with the full resolution gives the SNN rich features to evolve over. The minimum required neurons for a network was also automatically adjusted to 794 (784 inputs + 10 outputs).

3. **Elitism Count**
   * **Old Value**: 3
   * **New Value**: 5
   * **Reasoning**: Preserves a larger chunk of the highest-performing models between generations, lowering the chance that destructive crossovers and mutations ruin hard-found architectural improvements, especially on large-scale models.

4. **Training Samples per Generation**
   * **Old Value**: 200
   * **New Value**: 8000
   * **Reasoning**: Evaluating candidates on only 200 training samples led to heavy overfitting. By pushing the evaluation subset to 8,000 samples per generation out of the 48,000 available training images, the resulting fitness score much more accurately reflects the network's generalized performance, which should significantly boost the validation accuracy.
