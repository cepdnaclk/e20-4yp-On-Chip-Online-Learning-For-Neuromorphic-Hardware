/// @file mnist_main.cpp
/// @brief NOMAD-EONS MNIST training: evolve SNNs with 80/20 train/val split.
///
/// Uses the evolutionary SNN system to evolve genotypes on 80% of MNIST
/// training data, then validates the best 3 evolved SNN models on the
/// remaining 20%. Reports per-generation fitness and final top-3 accuracy.
///
/// Usage:
///   ./nomad_mnist <data_dir> [generations] [population_size] [seed]

#include "core/fixed_point.h"
#include "env/mnist_environment.h"
#include "env/mnist_loader.h"
#include "evo/evolution_unit.h"
#include "evo/genotype.h"
#include "memory/memory_cluster.h"
#include "noc/noc_mesh.h"
#include "core/module.h"
#include "core/signal.h"
#include <algorithm>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <memory>
#include <vector>

using namespace nomad;

// Forward declaration.
float compute_val_accuracy(const Genotype &genotype, const MNISTLoader &loader,
                            int offset, int count,
                            const MNISTEnvironment::Config &cfg);

/// @brief Holds a snapshot of a genotype and its fitness for top-3 tracking.
struct ModelRecord {
  Genotype genotype;
  float train_accuracy;
  float val_accuracy;
  int generation;
  float fitness;
};

int main(int argc, char *argv[]) {
  if (argc < 2) {
    std::cerr << "Usage: " << argv[0]
              << " <data_dir> [generations] [population_size] [seed]\n\n"
              << "  data_dir: directory with train-images-idx3-ubyte and "
                 "train-labels-idx1-ubyte\n";
    return 1;
  }

  std::string data_dir = argv[1];

  // ── Configuration ──────────────────────────────────────────
  int num_generations = 30;
  int population_size = 20;
  uint32_t seed = 0xDEADBEEF;

  if (argc >= 3) num_generations = std::atoi(argv[2]);
  if (argc >= 4) population_size = std::atoi(argv[3]);
  if (argc >= 5) seed = static_cast<uint32_t>(std::atol(argv[4]));

  if (num_generations <= 0) num_generations = 30;
  if (population_size < 4) population_size = 4;

  // ── Load full MNIST training data ──────────────────────────
  std::cout << "Loading MNIST dataset from: " << data_dir << "\n";
  MNISTLoader full_loader;
  if (!full_loader.load(data_dir, true, 0)) {  // Load ALL training data
    std::cerr << "Error: failed to load MNIST. Ensure directory contains:\n"
              << "  train-images-idx3-ubyte\n  train-labels-idx1-ubyte\n";
    return 1;
  }

  int total = full_loader.size();
  int train_count = static_cast<int>(total * 0.8);
  int val_count = total - train_count;

  std::cout << "Total samples:      " << total << "\n";
  std::cout << "Training (80%):     " << train_count << "\n";
  std::cout << "Validation (20%):   " << val_count << "\n\n";

  // ── Create separate train and validation loaders ───────────
  // Train loader: first 80% of samples
  MNISTLoader train_loader;
  train_loader.load(data_dir, true, train_count);

  // Validation loader: load all, then we'll evaluate on samples
  // [train_count .. total). We load the full set and use an offset
  // in the validation environment config.
  MNISTLoader val_loader;
  val_loader.load(data_dir, true, 0);  // Load all

  // ── Environment configs ────────────────────────────────────
  MNISTEnvironment::Config train_env_cfg;
  train_env_cfg.pixel_stride = 4;        // 7x7 = 49 input neurons
  train_env_cfg.cycles_per_sample = 30;
  train_env_cfg.num_eval_samples = 100;   // Evaluate on 100 training samples per genotype

  MNISTEnvironment::Config val_env_cfg;
  val_env_cfg.pixel_stride = 4;
  val_env_cfg.cycles_per_sample = 30;
  val_env_cfg.num_eval_samples = val_count; // Evaluate on ALL validation samples

  // Create training and validation environments
  MNISTEnvironment train_env(train_env_cfg, train_loader);
  MNISTEnvironment val_env(val_env_cfg, val_loader);

  // ── Evolution Unit config ──────────────────────────────────
  int num_inputs = train_env_cfg.num_input_neurons(); // 49
  int num_hidden = 141; // Adjusted for 200 total neurons
  int num_outputs = 10; // digits 0-9
  int total_neurons = num_inputs + num_hidden + num_outputs;

  EvolutionUnit::Config eu_cfg;
  eu_cfg.population_size = population_size;
  eu_cfg.num_neurons = total_neurons;
  eu_cfg.num_synapses = 200;
  eu_cfg.mutation_rate = 0.08f;
  eu_cfg.elitism_count = 3;
  eu_cfg.mesh_width = 3;
  eu_cfg.mesh_height = 3;
  eu_cfg.eval_cycles = 100;

  // ── Create hardware modules ────────────────────────────────
  NocMesh noc("noc", 3, 3);
  MemoryCluster mem("mem", 4096);
  EvolutionUnit eu("eu", eu_cfg, seed);

  noc.initialize();
  mem.initialize();
  eu.initialize();

  // ── Top-3 model tracking ───────────────────────────────────
  std::vector<ModelRecord> top3;

  // ── Print header ───────────────────────────────────────────
  std::cout
    << "╔════════════════════════════════════════════════════════════════════════╗\n"
    << "║            NOMAD-EONS MNIST SNN Evolution (Train/Val)                ║\n"
    << "╠════════════════════════════════════════════════════════════════════════╣\n"
    << "║  Population: " << std::setw(4) << population_size
    << "   Neurons: " << std::setw(3) << total_neurons
    << "   Synapses: " << std::setw(3) << eu_cfg.num_synapses
    << "   Seed: " << std::setw(10) << seed << "  ║\n"
    << "║  Mutation:  " << std::setw(5) << std::fixed << std::setprecision(2)
    << eu_cfg.mutation_rate
    << "   Elitism: " << std::setw(3) << eu_cfg.elitism_count
    << "   Stride: " << train_env_cfg.pixel_stride
    << "   Inputs: " << std::setw(3) << num_inputs
    << "              ║\n"
    << "╠════════════════════════════════════════════════════════════════════════╣\n"
    << "║ Gen │ Best Fit │ Avg Fit  │ Worst    │ Train Acc │ Val Acc │ Top-3?  ║\n"
    << "╠═════╪══════════╪══════════╪══════════╪═══════════╪═════════╪═════════╣\n";

  // ── Evolution loop ─────────────────────────────────────────
  for (int gen = 0; gen < num_generations; ++gen) {
    // Step 1: Evaluate all individuals on TRAINING set.
    train_env.evaluate_population(eu.population());

    // Step 2: Collect fitness statistics.
    auto &pop = eu.population();
    fp16_8 best_fit = pop[0].fitness;
    fp16_8 worst_fit = pop[0].fitness;
    float sum = 0.0f;
    int best_idx = 0;

    for (int i = 0; i < static_cast<int>(pop.size()); ++i) {
      if (pop[i].fitness > best_fit) {
        best_fit = pop[i].fitness;
        best_idx = i;
      }
      if (pop[i].fitness < worst_fit) {
        worst_fit = pop[i].fitness;
      }
      sum += pop[i].fitness.to_float();
    }

    float avg = sum / static_cast<float>(pop.size());
    
    // Print individual accuracy breakdown for this generation
    std::cout << "\n┌────────────────────────────────────────────────────────────────────┐\n"
              << "│  Generation " << std::setw(3) << gen << " / " << std::setw(3) << num_generations << "                                                       │\n"
              << "├────────┬────────────┬────────────┬────────────┬───────────────────┤\n"
              << "│ Model  │ Fitness    │ Train Acc  │ Val Acc    │ Status            │\n"
              << "├────────┼────────────┼────────────┼────────────┼───────────────────┤\n";
    
    float best_train_acc = 0.0f;
    float best_val_acc = 0.0f;

    for (int i = 0; i < static_cast<int>(pop.size()); ++i) {
      float m_train_acc = train_env.accuracy(pop[i]);
      float m_val_acc = compute_val_accuracy(pop[i], val_loader,
                                             train_count, val_count,
                                             train_env_cfg);
      
      std::string status = (i == best_idx) ? "BEST FITNESS" : "";
      if (i < eu_cfg.elitism_count && gen > 0) {
          if (status.empty()) status = "ELITE";
          else status += " (ELITE)";
      }

      std::cout << "│  " << std::setw(4) << i
                << "  │  " << std::setw(8) << std::fixed << std::setprecision(3) << pop[i].fitness.to_float()
                << "  │  " << std::setw(7) << std::setprecision(1) << (m_train_acc * 100.0f) << "%"
                << "  │  " << std::setw(7) << std::setprecision(1) << (m_val_acc * 100.0f) << "%"
                << "  │ " << std::setw(17) << std::left << status << std::right << " │\n";
    }

    // Step 3: Compute training accuracy for the best individual.
    float train_acc = train_env.accuracy(pop[best_idx]);

    // Step 4: Compute VALIDATION accuracy for the best individual.
    float val_acc = compute_val_accuracy(pop[best_idx], val_loader,
                                          train_count, val_count,
                                          train_env_cfg);
                                          
    std::cout << "├────────┴────────────┴────────────┴────────────┴───────────────────┤\n"
              << "│  Avg Fit: " << std::setw(7) << std::fixed << std::setprecision(3) << avg 
              << "   Best Val Acc: " << std::setw(6) << std::setprecision(1) << (val_acc * 100.0f) << "%                             │\n"
              << "└────────────────────────────────────────────────────────────────────┘\n\n";

    // Step 5: Track top-3 models by validation accuracy.
    bool is_top3 = false;
    ModelRecord rec;
    rec.genotype = pop[best_idx];
    rec.train_accuracy = train_acc;
    rec.val_accuracy = val_acc;
    rec.generation = gen;
    rec.fitness = best_fit.to_float();

    if (static_cast<int>(top3.size()) < 3) {
      top3.push_back(rec);
      is_top3 = true;
    } else {
      // Find the worst in top3.
      int worst_idx_t3 = 0;
      for (int i = 1; i < 3; ++i) {
        if (top3[i].val_accuracy < top3[worst_idx_t3].val_accuracy) {
          worst_idx_t3 = i;
        }
      }
      if (val_acc > top3[worst_idx_t3].val_accuracy) {
        top3[worst_idx_t3] = rec;
        is_top3 = true;
      }
    }

    std::cout << "║ " << std::setw(3) << gen
              << " │ " << std::setw(8) << std::fixed << std::setprecision(3) << best_fit.to_float()
              << " │ " << std::setw(8) << avg
              << " │ " << std::setw(8) << worst_fit.to_float()
              << " │ " << std::setw(7) << std::setprecision(1) << (train_acc * 100.0f) << "%"
              << "  │ " << std::setw(5) << (val_acc * 100.0f) << "%"
              << " │ " << (is_top3 ? "  ★ " : "    ") << "    ║\n";

    // Step 6: Trigger evolutionary cycle.
    eu.trigger.write(true);
    int safety = 0;
    do {
      eu.clk.write(true);
      eu.clk.write(false);
      safety++;
    } while (eu.state() != EUState::IDLE && safety < 100);
    eu.trigger.write(false);
  }

  // ── Sort top-3 by validation accuracy ──────────────────────
  std::sort(top3.begin(), top3.end(),
            [](const ModelRecord &a, const ModelRecord &b) {
              return a.val_accuracy > b.val_accuracy;
            });

  // ── Print results ──────────────────────────────────────────
  std::cout
    << "╠════════════════════════════════════════════════════════════════════════╣\n"
    << "║  Evolution complete: " << num_generations << " generations"
    << std::string(std::max(0, 48 - static_cast<int>(std::to_string(num_generations).size())), ' ')
    << "║\n"
    << "╚════════════════════════════════════════════════════════════════════════╝\n\n";

  std::cout
    << "╔════════════════════════════════════════════════════════════════════════╗\n"
    << "║                     TOP 3 BEST SNN MODELS                           ║\n"
    << "╠══════╤═══════════╤═════════════╤═════════════╤═════════╤═════════════╣\n"
    << "║ Rank │ Gen Found │ Train Acc   │ Val Acc     │ Fitness │ Structure   ║\n"
    << "╠══════╪═══════════╪═════════════╪═════════════╪═════════╪═════════════╣\n";

  for (int i = 0; i < static_cast<int>(top3.size()); ++i) {
    const auto &m = top3[i];
    std::cout << "║  #" << (i + 1) << "  │    "
              << std::setw(3) << m.generation << "    │   "
              << std::setw(6) << std::fixed << std::setprecision(2)
              << (m.train_accuracy * 100.0f) << "%   │   "
              << std::setw(6) << (m.val_accuracy * 100.0f) << "%   │ "
              << std::setw(7) << std::setprecision(3) << m.fitness << " │ "
              << std::setw(3) << m.genotype.neurons.size() << "N "
              << std::setw(3) << m.genotype.synapses.size() << "S"
              << "    ║\n";
  }

  std::cout
    << "╚══════╧═══════════╧═════════════╧═════════════╧═════════╧═════════════╝\n\n";

  // Print detailed info for each top-3 model.
  for (int i = 0; i < static_cast<int>(top3.size()); ++i) {
    const auto &m = top3[i];
    std::cout << "── Model #" << (i + 1) << " (Gen " << m.generation << ") ──\n";
    std::cout << "  Neurons:          " << m.genotype.neurons.size() << "\n";
    std::cout << "  Synapses:         " << m.genotype.synapses.size() << "\n";
    std::cout << "  Training Acc:     " << std::fixed << std::setprecision(2)
              << (m.train_accuracy * 100.0f) << "%\n";
    std::cout << "  Validation Acc:   " << (m.val_accuracy * 100.0f) << "%\n";
    std::cout << "  Fitness:          " << std::setprecision(3) << m.fitness << "\n";

    // Show a few neuron parameters.
    int show_n = std::min(5, static_cast<int>(m.genotype.neurons.size()));
    for (int n = 0; n < show_n; ++n) {
      const auto &np = m.genotype.neurons[n];
      std::cout << "  Neuron[" << n << "]: threshold="
                << std::setprecision(3) << np.threshold.to_float()
                << " leak=" << np.leak_rate.to_float()
                << " refrac=" << (int)np.refractory_period << "\n";
    }
    if (static_cast<int>(m.genotype.neurons.size()) > 5) {
      std::cout << "  ... (" << (m.genotype.neurons.size() - 5) << " more neurons)\n";
    }
    std::cout << "\n";
  }

  return 0;
}

/// @brief Compute validation accuracy on samples [offset, offset+count)
///        from the loaded dataset.
///
/// This evaluates the genotype on the validation portion of the data,
/// which starts at index `offset` in the loader.
float compute_val_accuracy(const Genotype &genotype, const MNISTLoader &loader,
                            int offset, int count,
                            const MNISTEnvironment::Config &cfg) {
  int num_neurons = static_cast<int>(genotype.neurons.size());
  int num_inputs = cfg.num_input_neurons();
  int num_outputs = cfg.num_output_neurons;

  if (num_neurons < num_inputs + num_outputs) {
    return 0.0f;
  }

  int output_start = num_neurons - num_outputs;

  // Clamp count to available data.
  if (offset + count > loader.size()) {
    count = loader.size() - offset;
  }
  if (count <= 0) return 0.0f;

  // Pre-compute downsampled pixel indices.
  std::vector<int> pixel_indices;
  for (int y = 0; y < 28; y += cfg.pixel_stride) {
    for (int x = 0; x < 28; x += cfg.pixel_stride) {
      pixel_indices.push_back(y * 28 + x);
    }
  }

  int correct = 0;

  for (int s = 0; s < count; ++s) {
    const auto &sample = loader[offset + s];

    // Create fresh neurons.
    std::vector<std::unique_ptr<NeuronLIF>> neurons;
    neurons.reserve(num_neurons);
    for (int i = 0; i < num_neurons; ++i) {
      auto neuron = std::make_unique<NeuronLIF>(
          "vn" + std::to_string(i), genotype.neurons[i]);
      neuron->initialize();
      neurons.push_back(std::move(neuron));
    }

    // Build synapse table.
    struct SynEntry { int dst; fp16_8 weight; };
    std::vector<std::vector<SynEntry>> syn_table(num_neurons);
    for (const auto &syn : genotype.synapses) {
      int src = syn.src_neuron % num_neurons;
      int dst = syn.dst_neuron % num_neurons;
      syn_table[src].push_back({dst, syn.weight});
    }

    // Simulate.
    for (int cycle = 0; cycle < cfg.cycles_per_sample; ++cycle) {
      for (int i = 0; i < num_inputs &&
                       i < static_cast<int>(pixel_indices.size()); ++i) {
        uint8_t pixel = sample.pixels[pixel_indices[i]];
        if (pixel > 0) {
          float intensity = static_cast<float>(pixel) / 255.0f;
          fp16_8 current = fp16_8::from_float(
              intensity * cfg.input_current_scale.to_float());
          neurons[i]->inject_current(current);
        }
      }

      for (auto &n : neurons) { n->clk.write(true); }
      for (auto &n : neurons) { n->clk.write(false); }

      for (int i = 0; i < num_neurons; ++i) {
        if (neurons[i]->fired.read()) {
          for (const auto &e : syn_table[i]) {
            neurons[e.dst]->inject_current(e.weight);
          }
        }
      }
    }

    // Decode output.
    int predicted = -1;
    uint32_t max_spikes = 0;
    for (int d = 0; d < num_outputs; ++d) {
      uint32_t spikes = neurons[output_start + d]->spike_count();
      if (spikes > max_spikes) {
        max_spikes = spikes;
        predicted = d;
      }
    }

    if (predicted == static_cast<int>(sample.label)) {
      correct++;
    }
  }

  return static_cast<float>(correct) / static_cast<float>(count);
}
