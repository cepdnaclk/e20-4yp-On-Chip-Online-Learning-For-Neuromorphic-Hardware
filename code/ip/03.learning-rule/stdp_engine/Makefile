# =============================================================================
# Makefile for STDP Engine
# Supports individual module tests and full integration test
# =============================================================================

# Directories
RTL_DIR = rtl
TB_DIR  = tb
BUILD_DIR = build

# Tools
IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

# RTL source files (order: leaf modules first, then dependent modules)
RTL_LEAF = $(RTL_DIR)/global_decay_timer.v \
           $(RTL_DIR)/trace_memory.v \
           $(RTL_DIR)/trace_increase_logic.v \
           $(RTL_DIR)/weight_update_logic.v \
           $(RTL_DIR)/neuron_index_to_address_encoder.v \
           $(RTL_DIR)/cluster_connection_matrix.v \
           $(RTL_DIR)/weight_distribution_receiver.v

RTL_MID  = $(RTL_DIR)/trace_update_module.v \
           $(RTL_DIR)/trace_update_arbiter.v \
           $(RTL_DIR)/banked_weight_memory.v \
           $(RTL_DIR)/weight_update_logic_bank_array.v \
           $(RTL_DIR)/spike_input_queue.v

RTL_TOP  = $(RTL_DIR)/stdp_controller.v \
           $(RTL_DIR)/neuron_cluster.v

RTL_ALL = $(RTL_LEAF) $(RTL_MID) $(RTL_TOP)

# Phony targets
.PHONY: all dir clean \
        test_global_decay_timer test_trace_memory test_trace_update_module \
        test_banked_weight_memory test_weight_update_logic test_spike_input_queue \
        test_neuron_cluster test_all

all: test_all

dir:
	@mkdir -p $(BUILD_DIR)

# =============================================================================
# Individual unit tests
# =============================================================================

test_global_decay_timer: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_global_decay_timer.vvp \
		$(RTL_DIR)/global_decay_timer.v \
		$(TB_DIR)/tb_global_decay_timer.v
	$(VVP) $(BUILD_DIR)/tb_global_decay_timer.vvp

test_trace_memory: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_trace_memory.vvp \
		$(RTL_DIR)/trace_memory.v \
		$(TB_DIR)/tb_trace_memory.v
	$(VVP) $(BUILD_DIR)/tb_trace_memory.vvp

test_trace_update_module: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_trace_update_module.vvp \
		$(RTL_DIR)/trace_increase_logic.v \
		$(RTL_DIR)/trace_update_module.v \
		$(TB_DIR)/tb_trace_update_module.v
	$(VVP) $(BUILD_DIR)/tb_trace_update_module.vvp

test_banked_weight_memory: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_banked_weight_memory.vvp \
		$(RTL_DIR)/banked_weight_memory.v \
		$(TB_DIR)/tb_banked_weight_memory.v
	$(VVP) $(BUILD_DIR)/tb_banked_weight_memory.vvp

test_weight_update_logic: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_weight_update_logic.vvp \
		$(RTL_DIR)/weight_update_logic.v \
		$(TB_DIR)/tb_weight_update_logic.v
	$(VVP) $(BUILD_DIR)/tb_weight_update_logic.vvp

test_spike_input_queue: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_spike_input_queue.vvp \
		$(RTL_DIR)/spike_input_queue.v \
		$(TB_DIR)/tb_spike_input_queue.v
	$(VVP) $(BUILD_DIR)/tb_spike_input_queue.vvp

test_neuron_cluster: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_neuron_cluster.vvp \
		$(RTL_ALL) \
		$(TB_DIR)/tb_neuron_cluster.v
	$(VVP) $(BUILD_DIR)/tb_neuron_cluster.vvp

# =============================================================================
# Run all tests
# =============================================================================

test_all: test_global_decay_timer test_trace_memory test_trace_update_module \
          test_banked_weight_memory test_weight_update_logic test_spike_input_queue \
          test_neuron_cluster
	@echo ""
	@echo "============================================"
	@echo "  All tests completed."
	@echo "============================================"

# =============================================================================
# Waveform viewers
# =============================================================================

wave_%:
	$(GTKWAVE) tb_$*.vcd &

# =============================================================================
# Cleanup
# =============================================================================

clean:
	rm -rf $(BUILD_DIR) *.vcd
