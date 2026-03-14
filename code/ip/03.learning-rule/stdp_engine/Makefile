# =============================================================================
# Makefile for STDP Engine
# Supports individual module tests and full integration test
# =============================================================================

# Directories
RTL_DIR   = rtl
TB_DIR    = tb
BUILD_DIR = build

# Tools
IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

# RTL source files (order: leaf modules first, then dependent modules)
# RTL_LEAF_NO_NEURON: all leaf files EXCEPT the real neuron model.
# Used by v2 integration test which provides its own stub.
RTL_LEAF_NO_NEURON = \
    $(RTL_DIR)/global_decay_timer.v \
    $(RTL_DIR)/trace_memory.v \
    $(RTL_DIR)/trace_increase_logic.v \
    $(RTL_DIR)/weight_update_logic.v \
    $(RTL_DIR)/neuron_index_to_address_encoder.v \
    $(RTL_DIR)/cluster_connection_matrix.v \
    $(RTL_DIR)/weight_distribution_receiver.v

RTL_NEURON_REAL = \
    $(RTL_DIR)/../../../01.neurons/lif_standard_weighted/rtl/Simple_LIF_Neuron_Model_Initial.v \
    $(RTL_DIR)/../../../01.neurons/lif_standard_weighted/utils/internal_neuron_accumulator/Internal_neuron_accumulator_v3.v \
    $(RTL_DIR)/../../../01.neurons/lif_standard_weighted/utils/internal_neuron_counter/Internal_Neuron_counter.v \
    $(RTL_DIR)/../../../01.neurons/lif_standard_weighted/utils/8bit_to_32bit_extender/8bit_to32bit_extender.v

RTL_LEAF = $(RTL_LEAF_NO_NEURON) $(RTL_NEURON_REAL)

RTL_MID = \
    $(RTL_DIR)/trace_update_module.v \
    $(RTL_DIR)/trace_update_arbiter.v \
    $(RTL_DIR)/banked_weight_memory.v \
    $(RTL_DIR)/weight_update_logic_bank_array.v \
    $(RTL_DIR)/spike_input_queue.v

RTL_TOP = \
    $(RTL_DIR)/stdp_controller.v \
    $(RTL_DIR)/neuron_cluster.v

RTL_ALL = $(RTL_LEAF) $(RTL_MID) $(RTL_TOP)

# RTL set for v2: real neuron files excluded — stub is inside the testbench
RTL_V2 = $(RTL_LEAF_NO_NEURON) $(RTL_MID) $(RTL_TOP)

# Phony targets
.PHONY: all dir clean \
        test_global_decay_timer test_trace_memory test_trace_update_module \
        test_banked_weight_memory test_weight_update_logic \
        test_weight_distribution_receiver test_spike_input_queue \
        test_neuron_cluster test_neuron_cluster_v2 test_all

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

test_weight_distribution_receiver: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_weight_distribution_receiver.vvp \
		$(RTL_DIR)/weight_distribution_receiver.v \
		$(TB_DIR)/tb_weight_distribution_receiver.v
	$(VVP) $(BUILD_DIR)/tb_weight_distribution_receiver.vvp

test_spike_input_queue: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_spike_input_queue.vvp \
		$(RTL_DIR)/spike_input_queue.v \
		$(TB_DIR)/tb_spike_input_queue.v
	$(VVP) $(BUILD_DIR)/tb_spike_input_queue.vvp

# Original integration test — uses real neuron files + init_weights.hex
test_neuron_cluster: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_neuron_cluster.vvp \
		$(RTL_ALL) \
		$(TB_DIR)/tb_neuron_cluster.v
	@cp $(TB_DIR)/init_weights.hex ./
	$(VVP) $(BUILD_DIR)/tb_neuron_cluster.vvp

# v2 integration test — 16-neuron, inline init, stub neuron
# Real neuron files are excluded. The stub (module neuron)
# is defined at the top of tb_neuron_cluster_v2.v.
# No init_weights.hex required — all memory set inline via direct assignment.
# New test groups vs v1:
#   Group A: Multi-input LTP    (neurons 5, 7, 9 → neuron 0)
#   Group B: Lazy-decay + LTP   (16 decay pulses then second spike)
#   Group C: LTP saturation     (W starts at 0xFF, must not overflow)
#   Group D: LTD underflow      (W starts at 0x00, must not wrap)
#   Group E: 4-way simultaneous spikes (queue serialisation stress)
#   Group F: Mid-run reset and clean restart
test_neuron_cluster_v2: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_neuron_cluster_v2.vvp \
		$(RTL_V2) \
		$(TB_DIR)/tb_neuron_cluster_v2.v
	$(VVP) $(BUILD_DIR)/tb_neuron_cluster_v2.vvp

# =============================================================================
# Run all tests
# =============================================================================

test_all: \
    test_global_decay_timer \
    test_trace_memory \
    test_trace_update_module \
    test_banked_weight_memory \
    test_weight_update_logic \
    test_weight_distribution_receiver \
    test_spike_input_queue \
    test_neuron_cluster_v2
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
	rm -rf $(BUILD_DIR) *.vcd *.hex
