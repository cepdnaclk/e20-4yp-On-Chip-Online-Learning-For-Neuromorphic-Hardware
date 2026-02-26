# Makefile for STDP Neuron Core
# Simulation setup for stdp_neuron_core.v

# Directories
# RTL is in the current directory (.) based on your description
RTL_DIR = .
TB_DIR = tb
# Using a local build directory to keep things clean
BUILD_DIR = build

# Tool Configuration
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Source Files
RTL_SOURCES = $(RTL_DIR)/stdp_neuron_core.v
TB_SOURCES = $(TB_DIR)/stdp_neuron_core_tb.v

# Output Target Name
TARGET = $(BUILD_DIR)/stdp_neuron_core

# Phony Targets
.PHONY: all sim clean wave dir

all: sim

# Run simulation
sim: $(TARGET)
	$(VVP) $(TARGET)

# Compile Verilog
$(TARGET): dir $(RTL_SOURCES) $(TB_SOURCES)
	$(IVERILOG) -o $(TARGET) -I$(RTL_DIR) $(TB_SOURCES) $(RTL_SOURCES)

# Open Waveform Viewer
wave:
	$(GTKWAVE) $(BUILD_DIR)/stdp_neuron_core.vcd &

# Create build directory if it doesn't exist
dir:
	@mkdir -p $(BUILD_DIR)

# Cleanup
clean:
	rm -rf $(BUILD_DIR)
