/// @file main.cpp
/// @brief NOMAD-EONS top-level simulation entry point.
///
/// Runs the full evolutionary simulation for XOR classification.
///
/// Usage:
///   ./nomad_eons [generations] [population_size] [seed]
///
/// Examples:
///   ./nomad_eons              # 50 generations, pop=8, default seed
///   ./nomad_eons 100          # 100 generations
///   ./nomad_eons 100 16       # 100 generations, pop=16
///   ./nomad_eons 100 16 42    # 100 generations, pop=16, seed=42

#include "system/nomad_system.h"
#include <cstdlib>
#include <iostream>

int main(int argc, char *argv[]) {
  nomad::NomadSystem::Config cfg;

  // Parse optional CLI arguments.
  if (argc >= 2)
    cfg.num_generations = std::atoi(argv[1]);
  if (argc >= 3)
    cfg.eu_config.population_size = std::atoi(argv[2]);
  if (argc >= 4)
    cfg.seed = static_cast<uint32_t>(std::atol(argv[3]));

  // Validate inputs.
  if (cfg.num_generations <= 0)
    cfg.num_generations = 50;
  if (cfg.eu_config.population_size < 4)
    cfg.eu_config.population_size = 4;

  // Sync mesh dimensions into EU config.
  cfg.eu_config.mesh_width = cfg.mesh_width;
  cfg.eu_config.mesh_height = cfg.mesh_height;

  // Create and run the system.
  nomad::NomadSystem system("nomad_eons", cfg);
  nomad::fp16_8 best = system.run();

  // Print final summary.
  std::cout << "\n";
  std::cout << "Fitness history: [";
  const auto &hist = system.fitness_history();
  for (size_t i = 0; i < hist.size(); ++i) {
    if (i > 0)
      std::cout << ", ";
    std::cout << hist[i].to_float();
  }
  std::cout << "]\n";

  // Print best individual details.
  const auto &best_ind = system.eu().best_individual();
  std::cout << "\nBest individual: " << best_ind << "\n";
  std::cout << "  Neurons:  " << best_ind.neurons.size() << "\n";
  std::cout << "  Synapses: " << best_ind.synapses.size() << "\n";
  for (size_t i = 0; i < best_ind.neurons.size(); ++i) {
    const auto &np = best_ind.neurons[i];
    std::cout << "  Neuron[" << i << "]: threshold=" << np.threshold.to_float()
              << " leak=" << np.leak_rate.to_float()
              << " refrac=" << (int)np.refractory_period << "\n";
  }

  return 0;
}
