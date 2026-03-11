/// @file mnist_main.cpp
/// @brief NOMAD-EONS simulation entry point for MNIST digit classification.
///
/// Evolves SNNs using rate-coded MNIST pixel inputs and spike-count
/// output decoding to classify handwritten digits.
///
/// Usage:
///   ./nomad_mnist <data_dir> [generations] [population_size] [seed]
///
/// Examples:
///   ./nomad_mnist ../data/mnist              # 30 gens, pop=20, default seed
///   ./nomad_mnist ../data/mnist 50           # 50 generations
///   ./nomad_mnist ../data/mnist 50 30        # 50 gens, pop=30
///   ./nomad_mnist ../data/mnist 50 30 42     # 50 gens, pop=30, seed=42

#include "env/mnist_loader.h"
#include "system/mnist_system.h"
#include <cstdlib>
#include <iostream>

int main(int argc, char *argv[]) {
  if (argc < 2) {
    std::cerr << "Usage: " << argv[0]
              << " <data_dir> [generations] [population_size] [seed]\n";
    std::cerr << "\n  data_dir: path to directory containing MNIST IDX files\n";
    std::cerr << "            (train-images-idx3-ubyte, "
                 "train-labels-idx1-ubyte)\n";
    return 1;
  }

  std::string data_dir = argv[1];

  nomad::MNISTSystem::Config cfg;

  // Parse optional CLI arguments.
  if (argc >= 3)
    cfg.num_generations = std::atoi(argv[2]);
  if (argc >= 4)
    cfg.eu_config.population_size = std::atoi(argv[3]);
  if (argc >= 5)
    cfg.seed = static_cast<uint32_t>(std::atol(argv[4]));

  // Validate inputs.
  if (cfg.num_generations <= 0)
    cfg.num_generations = 30;
  if (cfg.eu_config.population_size < 4)
    cfg.eu_config.population_size = 4;

  // Sync mesh dimensions into EU config.
  cfg.eu_config.mesh_width = cfg.mesh_width;
  cfg.eu_config.mesh_height = cfg.mesh_height;

  // Load MNIST data.
  std::cout << "Loading MNIST dataset from: " << data_dir << "\n";
  nomad::MNISTLoader loader;
  if (!loader.load(data_dir, true, cfg.env_config.num_eval_samples)) {
    std::cerr << "Error: failed to load MNIST data from " << data_dir << "\n";
    std::cerr << "Ensure the directory contains:\n";
    std::cerr << "  train-images-idx3-ubyte\n";
    std::cerr << "  train-labels-idx1-ubyte\n";
    return 1;
  }
  std::cout << "Loaded " << loader.size() << " MNIST samples.\n\n";

  // Create and run the system.
  nomad::MNISTSystem system("nomad_mnist", cfg, loader);
  nomad::fp16_8 best = system.run();

  // Print fitness history.
  std::cout << "\nFitness history: [";
  const auto &hist = system.fitness_history();
  for (size_t i = 0; i < hist.size(); ++i) {
    if (i > 0)
      std::cout << ", ";
    std::cout << hist[i].to_float();
  }
  std::cout << "]\n";

  // Print accuracy history.
  std::cout << "Accuracy history: [";
  const auto &acc_hist = system.accuracy_history();
  for (size_t i = 0; i < acc_hist.size(); ++i) {
    if (i > 0)
      std::cout << ", ";
    std::cout << (acc_hist[i] * 100.0f) << "%";
  }
  std::cout << "]\n";

  // Print best individual details.
  const auto &best_ind = system.eu().best_individual();
  std::cout << "\nBest individual: " << best_ind << "\n";
  std::cout << "  Neurons:  " << best_ind.neurons.size() << "\n";
  std::cout << "  Synapses: " << best_ind.synapses.size() << "\n";

  return 0;
}
