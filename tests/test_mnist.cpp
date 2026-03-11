/// @file test_mnist.cpp
/// @brief Integration tests for MNIST environment and system.
///
/// Tests:
///   1. MNISTLoader parses IDX files correctly (if dataset present).
///   2. MNISTEnvironment evaluates a genotype and returns valid fitness.
///   3. MNISTSystem runs multiple generations without crashing.
///   4. Rate-code encoding produces sensible spike patterns.
///
/// Run: ./build/test_mnist [data_dir]
///
/// If no data_dir is provided, tests requiring MNIST files are skipped.

#include "env/mnist_environment.h"
#include "env/mnist_loader.h"
#include "system/mnist_system.h"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace nomad;

static std::string g_data_dir = "";
static bool g_has_data = false;

// ── Helpers ──────────────────────────────────────────────────

void assert_in_range(float val, float lo, float hi, const char *msg) {
  if (val < lo || val > hi) {
    std::cerr << "FAIL: " << msg << " — expected [" << lo << ", " << hi
              << "] but got " << val << "\n";
    assert(false);
  }
}

// ── Test: MNIST Loader ──────────────────────────────────────

void test_mnist_loader() {
  std::cout << "  test_mnist_loader ... ";

  if (!g_has_data) {
    std::cout << "SKIP (no MNIST data directory provided)\n";
    return;
  }

  MNISTLoader loader;
  bool ok = loader.load(g_data_dir, true, 100);
  assert(ok);
  assert(loader.size() == 100);

  // Check first sample has valid properties.
  const auto &img = loader[0];
  assert(img.pixels.size() == 784);
  assert(img.label <= 9);

  // Check that pixels are in valid range [0, 255] (always true for uint8_t).
  // Check that not all pixels are zero (at least some content).
  int nonzero = 0;
  for (uint8_t p : img.pixels) {
    if (p > 0)
      nonzero++;
  }
  assert(nonzero > 0); // MNIST images should have some non-zero pixels.

  std::cout << "PASS (loaded " << loader.size()
            << " samples, first label=" << (int)img.label
            << " nonzero_pixels=" << nonzero << ")\n";
}

// ── Test: MNIST Environment evaluates a single genotype ─────

void test_mnist_environment_single() {
  std::cout << "  test_mnist_environment_single ... ";

  if (!g_has_data) {
    std::cout << "SKIP (no MNIST data)\n";
    return;
  }

  MNISTLoader loader;
  loader.load(g_data_dir, true, 20);

  MNISTEnvironment::Config env_cfg;
  env_cfg.pixel_stride = 4;   // 7x7 = 49 input neurons
  env_cfg.cycles_per_sample = 15;
  env_cfg.num_eval_samples = 20;

  MNISTEnvironment env(env_cfg, loader);

  // Create a random genotype with enough neurons.
  PRNG rng(42);
  int num_inputs = env_cfg.num_input_neurons(); // 49
  int num_total = num_inputs + 10 + 5;          // 64 total (49 in, 5 hidden, 10 out)
  Genotype g(num_total, 100);
  g.randomize(rng, 3, 3);

  fp16_8 fitness = env.evaluate(g);

  // Fitness should be non-negative.
  float f = fitness.to_float();
  assert(f >= 0.0f);

  // With random weights, accuracy should be around 10% (random guessing).
  float acc = env.accuracy(g);
  assert(acc >= 0.0f && acc <= 1.0f);

  std::cout << "PASS (fitness=" << f << " accuracy=" << (acc * 100.0f)
            << "%)\n";
}

// ── Test: MNISTSystem runs without crashing ─────────────────

void test_mnist_system_runs() {
  std::cout << "  test_mnist_system_runs ... ";

  if (!g_has_data) {
    std::cout << "SKIP (no MNIST data)\n";
    return;
  }

  MNISTLoader loader;
  loader.load(g_data_dir, true, 20);

  MNISTSystem::Config cfg;
  cfg.num_generations = 3;
  cfg.eu_config.population_size = 6;
  cfg.env_config.pixel_stride = 7; // 4x4 = 16 inputs (fast)
  cfg.env_config.cycles_per_sample = 10;
  cfg.env_config.num_eval_samples = 10;

  int num_inputs = cfg.env_config.num_input_neurons(); // 16
  cfg.eu_config.num_neurons = num_inputs + 10 + 4;     // 30
  cfg.eu_config.num_synapses = 50;
  cfg.eu_config.elitism_count = 1;
  cfg.eu_config.eval_cycles = 100;
  cfg.seed = 12345;
  cfg.verbose = false;

  MNISTSystem system("test_mnist_sys", cfg, loader);
  fp16_8 best = system.run();

  // System should complete all generations.
  assert(system.eu().generation() == 3);
  assert(system.fitness_history().size() == 3);
  assert(best >= fp16_8::zero());

  std::cout << "PASS (best=" << best.to_float()
            << " gen=" << system.eu().generation() << ")\n";
}

// ── Test: Rate-code encoding produces spikes ────────────────

void test_rate_code_encoding() {
  std::cout << "  test_rate_code_encoding ... ";

  // Create a simple test: bright pixel → high current → neuron fires.
  NeuronLIF::Params params;
  params.threshold = fp16_8::from_float(0.8f);
  params.leak_rate = fp16_8::from_float(0.05f);
  params.refractory_period = 1;

  NeuronLIF neuron("test_rate", params);
  neuron.initialize();

  // Inject high current (bright pixel) for several cycles.
  for (int c = 0; c < 20; ++c) {
    neuron.inject_current(fp16_8::from_float(1.0f)); // Bright pixel
    neuron.clk.write(true);
    neuron.clk.write(false);
  }

  // Neuron should have fired at least once with strong input.
  assert(neuron.spike_count() > 0);

  // Now test with zero current (dark pixel) — should not fire.
  NeuronLIF dark_neuron("test_dark", params);
  dark_neuron.initialize();

  for (int c = 0; c < 20; ++c) {
    // No current injection for dark pixel.
    dark_neuron.clk.write(true);
    dark_neuron.clk.write(false);
  }

  // Dark neuron should not fire (no input, leak drains any potential).
  assert(dark_neuron.spike_count() == 0);

  std::cout << "PASS (bright_spikes=" << neuron.spike_count()
            << " dark_spikes=" << dark_neuron.spike_count() << ")\n";
}

// ── Test: Genotype node count validation ────────────────────

void test_genotype_size_validation() {
  std::cout << "  test_genotype_size_validation ... ";

  MNISTLoader loader;

  // Even without data, we can test that the environment handles
  // undersize genotypes correctly.
  MNISTEnvironment::Config env_cfg;
  env_cfg.pixel_stride = 4; // 49 inputs needed
  env_cfg.num_eval_samples = 0;

  MNISTEnvironment env(env_cfg, loader);

  // Genotype too small: only 5 neurons for a task needing 59.
  Genotype g(5, 10);
  PRNG rng(99);
  g.randomize(rng);

  fp16_8 fitness = env.evaluate(g);
  // Should return zero — not enough neurons.
  assert(fitness == fp16_8::zero());

  std::cout << "PASS (undersize genotype returns zero fitness)\n";
}

// ── Main ─────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
  std::cout << "=== MNIST Tests ===\n";

  // Optional: provide MNIST data directory as argument.
  if (argc >= 2) {
    g_data_dir = argv[1];
    // Try to load a sample to verify data exists.
    MNISTLoader probe;
    g_has_data = probe.load(g_data_dir, true, 1);
    if (g_has_data) {
      std::cout << "  MNIST data found at: " << g_data_dir << "\n";
    } else {
      std::cout << "  MNIST data NOT found at: " << g_data_dir << "\n";
    }
  } else {
    std::cout << "  No MNIST data directory provided — data-dependent tests "
                 "will be skipped.\n";
    std::cout << "  Usage: " << argv[0] << " [mnist_data_dir]\n";
  }

  // Tests that don't require MNIST data.
  test_rate_code_encoding();
  test_genotype_size_validation();

  // Tests that require MNIST data.
  test_mnist_loader();
  test_mnist_environment_single();
  test_mnist_system_runs();

  std::cout << "=== All MNIST tests passed ===\n";
  return 0;
}
