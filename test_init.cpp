#include "evo/genotype.h"
#include "evo/prng.h"
#include <iostream>

using namespace nomad;

int main() {
    PRNG prng(42);
    Genotype g(10, 20);
    g.randomize(prng, 3, 3);
    for (int i=0; i<5; ++i) {
        std::cout << "Threshold: " << g.neurons[i].threshold.to_float() << " "
                  << "Leak: " << g.neurons[i].leak_rate.to_float() << " "
                  << "Refrac: " << (int)g.neurons[i].refractory_period << "\n";
    }
    for (int i=0; i<5; ++i) {
        std::cout << "Weight: " << g.synapses[i].weight.to_float() << "\n";
    }
    return 0;
}
