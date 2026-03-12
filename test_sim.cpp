#include "env/mnist_environment.h"
#include "env/mnist_loader.h"
#include "evo/genotype.h"
#include "evo/prng.h"
#include <iostream>

using namespace nomad;

int main() {
    MNISTLoader loader;
    if (!loader.load("data/mnist", true, 1)) return 1;

    MNISTEnvironment::Config cfg;
    cfg.pixel_stride = 4; // 7x7 = 49 inputs
    cfg.num_eval_samples = 1;
    cfg.cycles_per_sample = 30;

    PRNG rng(42);
    Genotype geno(200, 400); 
    geno.randomize(rng, 3, 3);
    
    // Evaluate and print inner states
    const auto& sample = loader[0];
    std::vector<std::unique_ptr<NeuronLIF>> neurons;
    for (int i = 0; i < 200; ++i) {
        auto neuron = std::make_unique<NeuronLIF>("n" + std::to_string(i), geno.neurons[i]);
        neuron->initialize();
        neurons.push_back(std::move(neuron));
    }
    
    struct SynEntry { int dst; fp16_8 weight; };
    std::vector<std::vector<SynEntry>> syn_table(200);
    for (const auto& syn : geno.synapses) {
        syn_table[syn.src_neuron % 200].push_back({syn.dst_neuron % 200, syn.weight});
    }
    
    std::vector<int> pixel_indices;
    for (int y = 0; y < 28; y += cfg.pixel_stride)
        for (int x = 0; x < 28; x += cfg.pixel_stride)
            pixel_indices.push_back(y * 28 + x);

    for (int cycle = 0; cycle < 5; ++cycle) {
        std::cout << "Cycle " << cycle << "\n";
        for (int i = 0; i < 49; ++i) {
            uint8_t pixel = sample.pixels[pixel_indices[i]];
            if (pixel > 0) {
                float intensity = static_cast<float>(pixel) / 255.0f;
                fp16_8 current = fp16_8::from_float(intensity * cfg.input_current_scale.to_float());
                neurons[i]->inject_current(current);
            }
        }
        for (auto& n : neurons) n->clk.write(true);
        for (auto& n : neurons) n->clk.write(false);
        for (int i = 0; i < 200; ++i) {
            if (neurons[i]->fired.read()) {
                std::cout << "  Neuron " << i << " fired!\n";
                for (const auto& e : syn_table[i]) neurons[e.dst]->inject_current(e.weight);
            }
        }
    // Trace paths from any input to any output
    std::cout << "\nSynapses total: " << geno.synapses.size() << "\n";
    int fwd_syn = 0;
    for (const auto& syn : geno.synapses) {
        if (syn.src_neuron < 49 && syn.dst_neuron >= 49 && syn.dst_neuron < 190) fwd_syn++;
    }
    std::cout << "Input -> Hidden Synapses: " << fwd_syn << "\n";

    fwd_syn = 0;
    for (const auto& syn : geno.synapses) {
        if (syn.src_neuron >= 49 && syn.src_neuron < 190 && syn.dst_neuron >= 190) fwd_syn++;
    }
    std::cout << "Hidden -> Output Synapses: " << fwd_syn << "\n";
    }

    std::vector<bool> reachable(200, false);
    for (int i = 0; i < 49; ++i) reachable[i] = true;

    // Run simple BFS
    bool changed;
    int failsafe = 0;
    do {
        changed = false;
        failsafe++;
        for (int i = 0; i < 200; ++i) {
            if (reachable[i]) {
                for (const auto& e : syn_table[i]) {
                    if (!reachable[e.dst]) {
                        reachable[e.dst] = true;
                        changed = true;
                    }
                }
            }
        }
    } while(changed && failsafe < 500);

    int reachable_outputs = 0;
    for (int i = 190; i < 200; ++i) {
        if (reachable[i]) reachable_outputs++;
    }
    std::cout << "Reachable output neurons: " << reachable_outputs << "/10\n";


    return 0;
}
