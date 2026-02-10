# Makefile for STDP Engine Module
# Spike-Timing-Dependent Plasticity Learning Engine

# Directories
RTL_DIR = rtl
TB_DIR = tb
BUILD_DIR = ../../../build

# Tool Configuration
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Source Files
RTL_SOURCES = $(RTL_DIR)/stdp_trace.v $(RTL_DIR)/weight_update.v
TB_SOURCES = $(TB_DIR)/tb_stdp_engine.v

# Targets
TARGET = $(BUILD_DIR)/stdp_engine

.PHONY: all sim clean wave

all: sim

sim: $(TARGET)
	$(VVP) $(TARGET)

$(TARGET): $(RTL_SOURCES) $(TB_SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -o $(TARGET) -I$(RTL_DIR) -I../../../global_inc $(TB_SOURCES) $(RTL_SOURCES)

wave:
	$(GTKWAVE) $(BUILD_DIR)/stdp_engine.vcd &

clean:
	rm -f $(BUILD_DIR)/stdp_engine*
