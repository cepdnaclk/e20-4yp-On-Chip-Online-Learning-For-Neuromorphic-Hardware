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

# =============================================================================
# MNIST configuration — override on the command line:
#   make test_mnist MNIST_IMAGES=500 MNIST_TIMESTEPS=30 MNIST_TOP_K=5
# =============================================================================
MNIST_IMAGES      ?= 200
MNIST_TIMESTEPS   ?= 20
MNIST_TOP_K       ?= 3
MNIST_INIT_WEIGHT ?= 200
MNIST_DATA_DIR    ?= data/mnist
MNIST_SPLIT       ?= test

# Phony targets
.PHONY: all dir clean download_mnist \
        test_global_decay_timer test_trace_memory test_trace_update_module \
        test_banked_weight_memory test_weight_update_logic \
        test_weight_distribution_receiver test_spike_input_queue \
        test_neuron_cluster test_neuron_cluster_v2 test_mnist test_all

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
# Real neuron files are excluded. The stub (simple_LIF_Neuron_Model)
# is defined at the top of tb_neuron_cluster_v2.v.
# No init_weights.hex required — all memory set inline via direct assignment.
test_neuron_cluster_v2: dir
	$(IVERILOG) -o $(BUILD_DIR)/tb_neuron_cluster_v2.vvp \
		$(RTL_V2) \
		$(TB_DIR)/tb_neuron_cluster_v2.v
	$(VVP) $(BUILD_DIR)/tb_neuron_cluster_v2.vvp


# =============================================================================
# STDP MNIST DEMO  (unsupervised learning + inference, end to end)
# =============================================================================
# Layout inside one 128-neuron cluster:
#   neurons   0..99   input layer  (10x10 downsampled MNIST, Poisson coded)
#   neurons 100..127  excitatory layer (winner-take-all, STDP-trained)
#
# Usage:
#   make mnist                 # prepare data, build, run, print accuracy
#   make mnist MNIST_IMAGES=1000
#   make mnist_prepare         # regenerate hex files only
#   make mnist_build           # compile only
#   make mnist_run             # run the already-built simulation
#
# Prerequisite: iverilog  (Arch: sudo pacman -S iverilog)
# MNIST IDX files must be in $(MNIST_DATA_DIR)/ -- see make download_mnist
# =============================================================================

MNIST_IMAGES      ?= 600
MNIST_TIMESTEPS   ?= 20
MNIST_GRID        ?= 10
MNIST_NEURONS     ?= 128
MNIST_NUM_EXC     ?= 28
MNIST_THRESHOLD   ?= 1200
MNIST_MAX_RATE    ?= 0.55
MNIST_SEED        ?= 1

RTL_STDP = \
    $(RTL_DIR)/global_decay_timer.v \
    $(RTL_DIR)/trace_memory.v \
    $(RTL_DIR)/trace_increase_logic.v \
    $(RTL_DIR)/weight_update_logic.v \
    $(RTL_DIR)/cluster_connection_matrix.v \
    $(RTL_DIR)/weight_distribution_receiver.v \
    $(RTL_DIR)/lif_neuron.v \
    $(RTL_DIR)/lateral_inhibition.v \
    $(RTL_DIR)/trace_update_module.v \
    $(RTL_DIR)/trace_update_arbiter.v \
    $(RTL_DIR)/banked_weight_memory.v \
    $(RTL_DIR)/weight_update_logic_bank_array.v \
    $(RTL_DIR)/spike_input_queue.v \
    $(RTL_DIR)/stdp_controller.v \
    $(RTL_DIR)/neuron_cluster.v

.PHONY: mnist mnist_prepare mnist_build mnist_run

mnist_prepare:
	@echo "=== Preparing MNIST spike data ==="
	python3 tools/prepare_mnist_stdp.py \
	    --images         $(MNIST_IMAGES) \
	    --timesteps      $(MNIST_TIMESTEPS) \
	    --grid           $(MNIST_GRID) \
	    --neurons        $(MNIST_NEURONS) \
	    --num-exc        $(MNIST_NUM_EXC) \
	    --base-threshold $(MNIST_THRESHOLD) \
	    --max-rate       $(MNIST_MAX_RATE) \
	    --seed           $(MNIST_SEED) \
	    --data-dir       $(MNIST_DATA_DIR) \
	    --out-dir        $(TB_DIR)
	@cp $(TB_DIR)/mnist_spikes.hex $(TB_DIR)/mnist_labels.hex $(TB_DIR)/init_weights.hex ./

mnist_build: dir
	@echo "=== Building STDP MNIST testbench ==="
	$(IVERILOG) -g2005 -I $(TB_DIR) -o $(BUILD_DIR)/tb_mnist_stdp.vvp \
	    $(RTL_STDP) $(TB_DIR)/tb_mnist_stdp.v

mnist_run:
	@echo "=== Running ==="
	$(VVP) $(BUILD_DIR)/tb_mnist_stdp.vvp

mnist: mnist_prepare mnist_build mnist_run

# =============================================================================
# LEGACY MNIST inference test (superseded by 'make mnist')
# =============================================================================
# Uses RTL_ALL (real simple_LIF_Neuron_Model) and 256 neurons.
#
# Step 1: Python generates mnist_spikes.hex, mnist_labels.hex, init_weights.hex
#         in tb/ using the MNIST_* variables above.
# Step 2: Iverilog compiles tb_mnist_inference.v with RTL_ALL.
# Step 3: VVP runs from the project root; hex files are copied here so
#         $readmemh("mnist_spikes.hex", ...) resolves correctly.
#
# Prerequisites:
#   pip install -r tools/requirements.txt
#   MNIST IDX files in $(MNIST_DATA_DIR)/   OR  run  make download_mnist  first.
#
# Quick examples:
#   make test_mnist                                    # 200 images, defaults
#   make test_mnist MNIST_IMAGES=500                   # 500 images
#   make test_mnist MNIST_IMAGES=100 MNIST_TIMESTEPS=30 MNIST_TOP_K=5
#   make test_mnist MNIST_INIT_WEIGHT=230              # higher weights → more firing
# =============================================================================

download_mnist:
	@echo "Downloading MNIST IDX files into $(MNIST_DATA_DIR)/ ..."
	@mkdir -p $(MNIST_DATA_DIR)
	python3 tools/prepare_mnist.py \
		--download \
		--images 1 \
		--data-dir $(MNIST_DATA_DIR) \
		--output-dir /tmp
	@echo "Download complete. Files are in $(MNIST_DATA_DIR)/"

test_mnist: dir
	@echo ""
	@echo "=== Step 1: Generating MNIST spike patterns ==="
	python3 tools/prepare_mnist.py \
		--images       $(MNIST_IMAGES) \
		--timesteps    $(MNIST_TIMESTEPS) \
		--top-k        $(MNIST_TOP_K) \
		--init-weight  $(MNIST_INIT_WEIGHT) \
		--split        $(MNIST_SPLIT) \
		--data-dir     $(MNIST_DATA_DIR) \
		--output-dir   $(TB_DIR)
	@echo ""
	@echo "=== Step 2: Compiling MNIST testbench ==="
	$(IVERILOG) -o $(BUILD_DIR)/tb_mnist_inference.vvp \
		$(RTL_ALL) \
		$(TB_DIR)/tb_mnist_inference.v
	@echo ""
	@echo "=== Step 3: Staging hex files ==="
	@cp $(TB_DIR)/mnist_spikes.hex ./
	@cp $(TB_DIR)/mnist_labels.hex ./
	@cp $(TB_DIR)/init_weights.hex ./
	@echo ""
	@echo "=== Step 4: Running simulation ==="
	$(VVP) $(BUILD_DIR)/tb_mnist_inference.vvp

# =============================================================================
# MNIST debug target — single image, all pipeline stages monitored
# Generates tb_mnist_debug.vcd for GTKWave.
#
# Run AFTER make test_mnist (reuses hex files already in tb/).
#   make test_mnist_debug        — compile and simulate
#   make wave_mnist_debug        — open waveform in GTKWave
# =============================================================================
test_mnist_debug: dir
	@echo "=== Compiling MNIST debug testbench ==="
	$(IVERILOG) -o $(BUILD_DIR)/tb_mnist_inference_debug.vvp \
		$(RTL_ALL) \
		$(TB_DIR)/tb_mnist_inference_debug.v
	@echo "=== Staging hex files (run make test_mnist first if missing) ==="
	@cp $(TB_DIR)/mnist_spikes.hex  ./ 2>/dev/null || \
	    (echo "ERROR: tb/mnist_spikes.hex missing — run 'make test_mnist' first." && exit 1)
	@cp $(TB_DIR)/mnist_labels.hex  ./
	@cp $(TB_DIR)/init_weights.hex  ./
	@echo "=== Running debug simulation ==="
	$(VVP) $(BUILD_DIR)/tb_mnist_inference_debug.vvp

wave_mnist_debug:
	$(GTKWAVE) tb_mnist_debug.vcd &

# =============================================================================
# Run all unit + integration tests (MNIST excluded — run separately)
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
	@echo "  All unit/integration tests completed."
	@echo "  Run 'make test_mnist' separately for MNIST."
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
