# Makefile for LIF Standard Neuron Module
# Leaky Integrate-and-Fire Neuron Simulation

# Directories
RTL_DIR = rtl
TB_DIR = tb
BUILD_DIR = ../../../build

# Tool Configuration
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Source Files
RTL_SOURCES = $(RTL_DIR)/lif_core.v $(RTL_DIR)/leak_logic.v
TB_SOURCES = $(TB_DIR)/tb_lif_single.v

# Targets
TARGET = $(BUILD_DIR)/lif_standard

.PHONY: all sim clean wave

all: sim

sim: $(TARGET)
	$(VVP) $(TARGET)

$(TARGET): $(RTL_SOURCES) $(TB_SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -o $(TARGET) -I$(RTL_DIR) -I../../../global_inc $(TB_SOURCES) $(RTL_SOURCES)

wave:
	$(GTKWAVE) $(BUILD_DIR)/lif_standard.vcd &

clean:
	rm -f $(BUILD_DIR)/lif_standard*
