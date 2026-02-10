# Makefile for AER RX/TX Module
# Address Event Representation Interface

# Directories
RTL_DIR = rtl
TB_DIR = tb
BUILD_DIR = ../../../build

# Tool Configuration
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Source Files
RTL_SOURCES = $(RTL_DIR)/aer_decoder.v $(RTL_DIR)/spike_buffer.v
TB_SOURCES = $(TB_DIR)/tb_aer_rx_tx.v

# Targets
TARGET = $(BUILD_DIR)/aer_rx_tx

.PHONY: all sim clean wave

all: sim

sim: $(TARGET)
	$(VVP) $(TARGET)

$(TARGET): $(RTL_SOURCES) $(TB_SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) -o $(TARGET) -I$(RTL_DIR) -I../../../global_inc $(TB_SOURCES) $(RTL_SOURCES)

wave:
	$(GTKWAVE) $(BUILD_DIR)/aer_rx_tx.vcd &

clean:
	rm -f $(BUILD_DIR)/aer_rx_tx*
