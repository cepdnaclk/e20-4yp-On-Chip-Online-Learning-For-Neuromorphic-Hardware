# Makefile for STDP Engine Module
# Spike-Timing-Dependent Plasticity Learning Engine

# Directories
RTL_DIR  = rtl
TB_DIR   = tb
BUILD_DIR = ../../../build

# Tool Configuration
IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

# -----------------------------------------------------------------------
# neuron_cluster target
# -----------------------------------------------------------------------
NC_RTL_SOURCES = $(RTL_DIR)/neuron_cluster.v
NC_TB_SOURCES  = $(TB_DIR)/tb_neuron_cluster.v
NC_TARGET      = $(BUILD_DIR)/neuron_cluster

.PHONY: all sim sim_nc wave_nc clean

all: sim

# Default simulation target: neuron_cluster testbench
sim: sim_nc

sim_nc: $(NC_TARGET)
	$(VVP) $(NC_TARGET)

$(NC_TARGET): $(NC_RTL_SOURCES) $(NC_TB_SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -o $(NC_TARGET) -I$(RTL_DIR) -I../../../global_inc \
	    $(NC_TB_SOURCES) $(NC_RTL_SOURCES)

wave_nc:
	$(GTKWAVE) $(BUILD_DIR)/tb_neuron_cluster.vcd &

clean:
	rm -f $(BUILD_DIR)/neuron_cluster*
