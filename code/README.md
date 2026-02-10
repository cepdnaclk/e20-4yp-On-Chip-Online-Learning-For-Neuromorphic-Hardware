Project/
├── global_inc/                  # System-wide parameters (Thresholds, bit-widths)
│   ├── neuro_defines.vh         # Macros: SPIKE_WIDTH, TIME_STEP, NUM_NEURONS
│   └── aer_pkg.sv               # SystemVerilog package for AER packet structs
│
├── scripts/                     # Automation
│   ├── weight_gen.py            # Script to generate initial weight .hex files
│   └── spike_monitor.py         # Script to visualize spike rasters from simulation
│
├── build/                       # Simulation artifacts (waves, logs)
│
└── ip/                          # Your "Commons" Library
    │
    ├── neurons/                 # Neuron Models (The computational cores)
    │   ├── lif_standard/        # Leaky Integrate-and-Fire Neuron
    │   │   ├── rtl/
    │   │   │   ├── lif_core.v        # Membrane potential update logic
    │   │   │   └── leak_logic.v      # Decay mechanism
    │   │   ├── tb/
    │   │   │   ├── tb_lif_single.v   # Single neuron test
    │   │   │   └── spike_patterns.hex
    │   │   └── Makefile
    │   └── izhikevich/          # Complex neuron model (if needed)
    │
    ├── plasticity/              # Learning Engines (The "Online Learning" part)
    │   ├── stdp_engine/         # Spike-Timing-Dependent Plasticity
    │   │   ├── rtl/
    │   │   │   ├── stdp_trace.v      # Trace update logic
    │   │   │   └── weight_update.v   # Potentiation/Depression logic
    │   │   ├── tb/
    │   │   └── Makefile
    │   └── r_stdp/              # Reward-modulated STDP (for reinforcement)
    │
    ├── interconnect/            # Communication (Network-on-Chip)
    │   ├── aer_rx_tx/           # Address Event Representation Interface
    │   │   ├── rtl/
    │   │   │   ├── aer_decoder.v     # Decodes incoming spike addresses
    │   │   │   └── spike_buffer.v    # FIFO for spike events
    │   │   ├── tb/
    │   │   └── Makefile
    │   └── crossbar/            # Synaptic crossbar logic or router
    │
    └── encoding/                # Input/Output handling
        └── spike_encoder/       # Converts sensor values to spike trains
            ├── rtl/
            │   ├── rate_coder.v      # Rate coding logic
            │   └── temporal_coder.v  # Time-to-First-Spike logic
            └── tb/
