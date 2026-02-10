# Scripts Directory

This directory contains automation scripts for data generation, visualization, and analysis.

## Scripts

### weight_gen.py
Generates initial synaptic weight files in `.hex` format for simulation and synthesis.

**Usage:**
```bash
python weight_gen.py --neurons <num> --output <filename.hex>
```

**Features:**
- Random weight initialization
- Configurable weight distributions
- Support for multiple weight matrix formats

### spike_monitor.py
Visualizes spike rasters from simulation output files.

**Usage:**
```bash
python spike_monitor.py --input <simulation_log> --output <plot.png>
```

**Features:**
- Real-time spike visualization
- Raster plot generation
- Statistical analysis of firing patterns

## Requirements

Install dependencies using:
```bash
pip install -r requirements.txt
```
