# NOMAD-EONS: Key Parameters Explained

## Population

The **population** is the number of SNN (Spiking Neural Network) individuals that exist simultaneously in each generation. Each individual is a complete neural network with its own unique set of neuron parameters and synaptic connections (encoded as a **Genotype**).

- A **larger population** (e.g., 20–40) explores more diverse solutions per generation but takes longer to evaluate.
- A **smaller population** (e.g., 6–10) runs faster but may converge prematurely to suboptimal solutions.

> **Analogy**: Think of it as the number of students in a class taking the same exam. More students = higher chance one of them scores well.

---

## Seed

The **seed** is a starting value for the Pseudo-Random Number Generator (PRNG). It controls all randomness in the system:

- Initial random genotype generation (neuron thresholds, synapse weights, connections)
- Tournament selection (which individuals compete)
- Crossover points and mutation locations

**Same seed = same results every time** (deterministic). This is critical for:

- **Reproducibility**: Re-running with seed `42` always produces identical evolution.
- **Comparison**: Changing one parameter while keeping the seed fixed lets you isolate its effect.
- **Hardware verification**: The C++ model must match the Verilog RTL bit-for-bit.

---

## Elitism

**Elitism** is the number of top-performing individuals that are copied directly into the next generation *without* crossover or mutation.

- With `elitism_count = 3`, the 3 fittest SNNs survive unchanged to the next generation.
- The remaining `population_size - elitism_count` slots are filled by offspring (crossover + mutation of selected parents).

**Why it matters**:

- **Prevents regression**: Without elitism, a lucky high-fitness genotype could be lost if its offspring happen to be worse.
- **Guarantees monotonic improvement**: Best fitness can never decrease across generations.
- **Trade-off**: Too much elitism reduces diversity and slows exploration of new solutions.

---

## Stride (Pixel Stride)

**Stride** controls the downsampling of MNIST images (28×28 pixels) into SNN input neurons. It determines how many pixels are skipped when mapping the image to input neurons.

| Stride | Input Image Size | Input Neurons | Detail Level |
|--------|-----------------|---------------|-------------|
| 1      | 28×28           | 784           | Full resolution |
| 2      | 14×14           | 196           | Half resolution |
| **4**  | **7×7**         | **49**        | **Quarter resolution (default)** |
| 7      | 4×4             | 16            | Very coarse |

- **Smaller stride** = more input neurons = more detail, but much slower evolution (more neurons to simulate).
- **Larger stride** = fewer input neurons = faster but loses fine detail.
- **Stride 4** (49 inputs) is the default balance between speed and classification capability.

Each selected pixel's intensity (0–255) is converted to a proportional input current injected into its corresponding input neuron every clock cycle (**rate coding**).

---

## Fitness

**Fitness** is a numerical score measuring how well an SNN genotype performs on the MNIST classification task. It is the evolutionary pressure that drives improvement — higher fitness = better chance of being selected as a parent.

### How it's calculated

For each MNIST sample evaluated, the genotype can earn:

| Result | Points | Description |
|--------|--------|-------------|
| Correct classification | **+1.0** | The output neuron with most spikes matches the digit label |
| Confidence bonus | **+0.1** | Correct AND the winning output neuron fired >1 spike |
| Partial credit | **+0.0 to +0.5** | Wrong answer, but the correct output neuron did fire (proportional to its activity) |
| No output activity | **0** | None of the 10 output neurons fired |

### Fitness vs Accuracy

- **Fitness** includes partial credit and bonuses → provides a smooth gradient for evolution. Even "almost correct" genotypes get rewarded, helping guide selection toward better solutions.
- **Accuracy** is strict binary correctness → what % of digits were classified exactly right.

> **Example**: A genotype evaluated on 100 samples with fitness = 58.0 may have ~30 correct classifications (+30.0), several with confidence bonuses (+3.0–5.0), and many partial credits (~20.0). Its accuracy would be ~30%, but fitness captures that it was "close" on many others.

### Why not just use accuracy?

In early generations, most random SNNs get 10% accuracy (random guessing for 10 digits). If fitness were just 0/1 per sample, nearly all individuals would look equally bad, giving evolution no signal to improve. Partial credit lets evolution distinguish between "almost works" and "completely wrong."
