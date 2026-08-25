// =============================================================================
// tb_mnist_inference_debug.v
// Diagnostic version of tb_mnist_inference.
//
// Changes from the main testbench:
//   - Runs only ONE image (image 0) for ONE timestep then stops.
//     This keeps the VCD file small enough to inspect in GTKWave.
//   - $dumpvars covers ALL four pipeline stages explicitly.
//   - $display probes print on every rising edge where something important
//     changes, so you can read the transcript without even opening GTKWave.
//   - Parameters are kept at 256 neurons / real LIF to match production.
//
// Run with:   make test_mnist_debug
// Open VCD:   make wave_mnist_debug
//
// What to look for (transcript):
//   Stage 1 — queue_empty should go LOW within 2 cycles of the spike burst.
//             If it never does, the spike bus is not being captured.
//   Stage 2 — dist_valid should pulse HIGH during STDP drain.
//             If it never does, the STDP controller is not distributing weights.
//   Stage 3 — receiver_valid[0..9] should pulse HIGH after dist_valid.
//             If it never does, the weight distribution receiver is broken.
//   Stage 4 — input_spike on output neuron should pulse HIGH after receiver.
//             If it never does, the LIF neuron never receives a synaptic input.
//   Stage 5 — output_spike[0..9] should eventually go HIGH.
//             If it never does, LIF threshold is too high for accumulated weight.
// =============================================================================

`timescale 1ns/1ps

module tb_mnist_inference_debug;

    // =========================================================================
    // Parameters — identical to tb_mnist_inference
    // =========================================================================
    parameter N_IMAGES          = 200;
    parameter TIMESTEPS_PER_IMG = 40;
    parameter CLK_PERIOD_NS     = 10;
    parameter MAX_SIM_CYCLES    = 5_000_000;
    parameter STDP_WAIT_CYCLES  = 6000;

    parameter NUM_NEURONS_PER_CLUSTER    = 256;
    parameter NEURON_ADDRESS_WIDTH       = 8;
    parameter NUM_WEIGHT_BANKS           = 256;
    parameter WEIGHT_BANK_ADDRESS_WIDTH  = 8;
    parameter WEIGHT_BIT_WIDTH           = 8;
    parameter TRACE_VALUE_BIT_WIDTH      = 8;
    parameter DECAY_TIMER_BIT_WIDTH      = 12;
    parameter TRACE_SATURATION_THRESHOLD = 256;
    parameter DECAY_SHIFT_LOG2           = 3;
    parameter TRACE_INCREMENT_VALUE      = 32;
    parameter NUM_TRACE_UPDATE_MODULES   = 4;
    parameter SPIKE_QUEUE_DEPTH          = 256;
    parameter LTP_SHIFT_AMOUNT           = 2;
    parameter LTD_SHIFT_AMOUNT           = 2;
    parameter INCREASE_MODE              = 0;

    parameter OUTPUT_START = 0;
    parameter OUTPUT_END   = 9;
    parameter HIDDEN_START = 10;
    parameter HIDDEN_END   = 209;

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg  clock;
    reg  reset;
    reg  global_cluster_enable;
    reg  decay_enable_pulse;
    reg  [NUM_NEURONS_PER_CLUSTER-1:0] external_spike_input_bus;
    wire [NUM_NEURONS_PER_CLUSTER-1:0] cluster_spike_output_bus;
    wire                               cluster_busy_flag;

    // =========================================================================
    // DUT
    // =========================================================================
    neuron_cluster #(
        .NUM_NEURONS_PER_CLUSTER    (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH       (NEURON_ADDRESS_WIDTH),
        .NUM_WEIGHT_BANKS           (NUM_WEIGHT_BANKS),
        .WEIGHT_BANK_ADDRESS_WIDTH  (WEIGHT_BANK_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH           (WEIGHT_BIT_WIDTH),
        .TRACE_VALUE_BIT_WIDTH      (TRACE_VALUE_BIT_WIDTH),
        .DECAY_TIMER_BIT_WIDTH      (DECAY_TIMER_BIT_WIDTH),
        .TRACE_SATURATION_THRESHOLD (TRACE_SATURATION_THRESHOLD),
        .DECAY_SHIFT_LOG2           (DECAY_SHIFT_LOG2),
        .TRACE_INCREMENT_VALUE      (TRACE_INCREMENT_VALUE),
        .NUM_TRACE_UPDATE_MODULES   (NUM_TRACE_UPDATE_MODULES),
        .SPIKE_QUEUE_DEPTH          (SPIKE_QUEUE_DEPTH),
        .LTP_SHIFT_AMOUNT           (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT           (LTD_SHIFT_AMOUNT),
        .INCREASE_MODE              (INCREASE_MODE)
    ) uut (
        .clock                    (clock),
        .reset                    (reset),
        .global_cluster_enable    (global_cluster_enable),
        .decay_enable_pulse       (decay_enable_pulse),
        .external_spike_input_bus (external_spike_input_bus),
        .cluster_spike_output_bus (cluster_spike_output_bus),
        .cluster_busy_flag        (cluster_busy_flag)
    );

    // =========================================================================
    // Clock + watchdog
    // =========================================================================
    initial clock = 0;
    always #(CLK_PERIOD_NS/2) clock = ~clock;

    initial begin
        #(CLK_PERIOD_NS * MAX_SIM_CYCLES);
        $display("[WATCHDOG] Hit %0d cycle limit. Stopping.", MAX_SIM_CYCLES);
        $finish;
    end

    // =========================================================================
    // Data arrays
    // =========================================================================
    reg [255:0] spike_patterns [0:N_IMAGES*TIMESTEPS_PER_IMG-1];
    reg [3:0]   image_labels   [0:N_IMAGES-1];
    reg [7:0]   flat_weights   [0:NUM_WEIGHT_BANKS*256-1];

    // =========================================================================
    // VCD dump — explicitly names every stage for GTKWave
    // =========================================================================
    initial begin
        $dumpfile("tb_mnist_debug.vcd");

        // Top-level: visible ports + busy flag
        $dumpvars(0, tb_mnist_inference_debug.clock);
        $dumpvars(0, tb_mnist_inference_debug.reset);
        $dumpvars(0, tb_mnist_inference_debug.external_spike_input_bus);
        $dumpvars(0, tb_mnist_inference_debug.cluster_spike_output_bus);
        $dumpvars(0, tb_mnist_inference_debug.cluster_busy_flag);
        $dumpvars(0, tb_mnist_inference_debug.decay_enable_pulse);

        // ── Stage 1: Spike queue ──────────────────────────────────────────
        // UPDATE PATH if your spike_input_queue instance name differs
        $dumpvars(0, uut.spike_queue_inst.incoming_spike_bus);
        $dumpvars(0, uut.spike_queue_inst.queue_empty_flag);
        $dumpvars(0, uut.spike_queue_inst.queue_full_flag);
        $dumpvars(0, uut.spike_queue_inst.dequeued_spike_neuron_address);
        $dumpvars(0, uut.spike_queue_inst.dequeued_spike_valid);
        $dumpvars(0, uut.spike_queue_inst.dequeue_acknowledge);

        // ── Stage 2: STDP controller outputs ─────────────────────────────
        // UPDATE PATH if your stdp_controller instance name differs
        $dumpvars(0, uut.stdp_ctrl_inst.stdp_controller_busy_flag);
        $dumpvars(0, uut.stdp_ctrl_inst.fired_neuron_address);
        $dumpvars(0, uut.stdp_ctrl_inst.fired_neuron_address_valid);

        // ── Stage 3: Weight distribution bus ─────────────────────────────
        $dumpvars(0, uut.dist_bus_data_wire);
        $dumpvars(0, uut.dist_bus_target_addr_wire);
        $dumpvars(0, uut.dist_bus_valid_wire);

        // ── Stage 4: Weight receivers for output neurons 0–3 ─────────────
        // UPDATE PATH if your generate label / instance names differ
        $dumpvars(0, uut.gen_neurons[0].weight_receiver_inst.held_weight_value);
        $dumpvars(0, uut.gen_neurons[0].weight_receiver_inst.held_weight_valid_flag);
        $dumpvars(0, uut.gen_neurons[1].weight_receiver_inst.held_weight_valid_flag);
        $dumpvars(0, uut.gen_neurons[2].weight_receiver_inst.held_weight_valid_flag);
        $dumpvars(0, uut.gen_neurons[3].weight_receiver_inst.held_weight_valid_flag);

        // ── Stage 5: LIF neuron inputs + outputs for neurons 0–3 ─────────
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.clock);
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.reset);
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.enable);
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.input_spike_wire);
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.synaptic_weight_wire);
        $dumpvars(0, uut.gen_neurons[0].neuron_inst.spike_output_wire);
        $dumpvars(0, uut.gen_neurons[1].neuron_inst.input_spike_wire);
        $dumpvars(0, uut.gen_neurons[1].neuron_inst.spike_output_wire);
        $dumpvars(0, uut.gen_neurons[2].neuron_inst.input_spike_wire);
        $dumpvars(0, uut.gen_neurons[2].neuron_inst.spike_output_wire);
        $dumpvars(0, uut.gen_neurons[3].neuron_inst.input_spike_wire);
        $dumpvars(0, uut.gen_neurons[3].neuron_inst.spike_output_wire);

        // Dump ALL internals of neuron 0 (includes membrane potential)
        $dumpvars(1, uut.gen_neurons[0].neuron_inst);
    end

    // =========================================================================
    // Event monitors — print every time a key signal changes
    // These fire in parallel with the main initial block.
    // =========================================================================

    // Stage 1: queue fill events
    always @(negedge uut.spike_queue_inst.queue_empty_flag)
        $display("[DBG S1] t=%0t  queue_empty → LOW  (spikes captured)", $time);
    always @(posedge uut.spike_queue_inst.queue_empty_flag)
        $display("[DBG S1] t=%0t  queue_empty → HIGH (queue drained)", $time);
    always @(posedge uut.spike_queue_inst.dequeued_spike_valid)
        $display("[DBG S1] t=%0t  dequeued neuron addr = %0d",
                 $time, uut.spike_queue_inst.dequeued_spike_neuron_address);

    // Stage 2: weight distribution pulses
    always @(posedge uut.dist_bus_valid_wire)
        $display("[DBG S2] t=%0t  dist_bus VALID  data=0x%02h  target_neuron=%0d",
                 $time, uut.dist_bus_data_wire, uut.dist_bus_target_addr_wire);

    // Stage 3: receiver valid pulse on output neuron 0
    always @(posedge uut.gen_neurons[0].weight_receiver_inst.held_weight_valid_flag)
        $display("[DBG S3] t=%0t  receiver[0] captured weight = %0d",
                 $time, uut.gen_neurons[0].weight_receiver_inst.held_weight_value);

    // Stage 4: LIF input spike on output neuron 0
    always @(posedge uut.gen_neurons[0].neuron_inst.input_spike_wire)
        $display("[DBG S4] t=%0t  LIF[0] input_spike_wire HIGH  weight=%0d",
                 $time, uut.gen_neurons[0].neuron_inst.synaptic_weight_wire);

    // Stage 5: output neuron fires
    always @(posedge uut.gen_neurons[0].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 0 FIRED ***", $time);
    always @(posedge uut.gen_neurons[1].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 1 FIRED ***", $time);
    always @(posedge uut.gen_neurons[2].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 2 FIRED ***", $time);
    always @(posedge uut.gen_neurons[3].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 3 FIRED ***", $time);
    always @(posedge uut.gen_neurons[4].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 4 FIRED ***", $time);
    always @(posedge uut.gen_neurons[5].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 5 FIRED ***", $time);
    always @(posedge uut.gen_neurons[6].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 6 FIRED ***", $time);
    always @(posedge uut.gen_neurons[7].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 7 FIRED ***", $time);
    always @(posedge uut.gen_neurons[8].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 8 FIRED ***", $time);
    always @(posedge uut.gen_neurons[9].neuron_inst.spike_output_wire)
        $display("[DBG S5] t=%0t  *** OUTPUT NEURON 9 FIRED ***", $time);

    // =========================================================================
    // Helper tasks (copy of drain_stdp from main testbench)
    // =========================================================================
    integer wait_cyc;

    task drain_stdp;
        input integer timeout;
        begin
            wait_cyc = 0;
            while (cluster_busy_flag && wait_cyc < timeout) begin
                @(posedge clock);
                wait_cyc = wait_cyc + 1;
            end
            #1;
        end
    endtask

    // =========================================================================
    // Main diagnostic body
    // Runs only image 0, timestep 0, then waits long enough to see whether
    // any part of the pipeline responds. Prints a stage-by-stage verdict.
    // =========================================================================
    integer o_i, b_i, a_i;
    integer dist_pulse_count;
    integer recv_pulse_count;
    integer lif_input_count;
    integer output_spike_count;

    initial begin
        $display("==========================================================");
        $display("  MNIST Debug Testbench — single image, single timestep");
        $display("  Monitoring pipeline stage by stage.");
        $display("  Read the [DBG Sx] lines to find where signal flow stops.");
        $display("==========================================================");

        // ── Load hex files ────────────────────────────────────────────────
        $readmemh("mnist_spikes.hex", spike_patterns);
        $readmemh("mnist_labels.hex", image_labels);
        $readmemh("init_weights.hex", flat_weights);

        // ── Reset ─────────────────────────────────────────────────────────
        reset                    = 1;
        global_cluster_enable    = 0;
        decay_enable_pulse       = 0;
        external_spike_input_bus = {NUM_NEURONS_PER_CLUSTER{1'b0}};
        repeat(8) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // ── Program weights ───────────────────────────────────────────────
        begin : weight_load
            integer bk, ad;
            for (bk = 0; bk < NUM_WEIGHT_BANKS; bk = bk + 1)
                for (ad = 0; ad < 256; ad = ad + 1)
                    uut.weight_memory_inst.bank_memory[bk][ad] =
                        flat_weights[bk * 256 + ad];
        end
        @(posedge clock); #1;

        // ── Configure connections ─────────────────────────────────────────
        begin : conn_load
            integer out_n, hid_n;
            for (out_n = OUTPUT_START; out_n <= OUTPUT_END; out_n = out_n + 1)
                for (hid_n = HIDDEN_START; hid_n <= HIDDEN_END; hid_n = hid_n + 1) begin
                    uut.connection_matrix_inst.connection_table[out_n][hid_n] = 2'b10;
                    uut.connection_matrix_inst.connection_table[hid_n][out_n] = 2'b01;
                end
        end
        @(posedge clock); #1;

        // ── Print the first spike pattern so we know what we're sending ───
        $display("");
        $display("[INFO] Image 0 label = %0d", image_labels[0]);
        $display("[INFO] Timestep 0 spike bus = 0x%064h", spike_patterns[0]);
        $display("[INFO] Active hidden neurons in timestep 0:");
        begin : count_spikes
            integer bit_i;
            integer spike_count;
            spike_count = 0;
            for (bit_i = 10; bit_i <= 209; bit_i = bit_i + 1) begin
                if (spike_patterns[0][bit_i]) begin
                    $display("         bit %0d (hidden neuron %0d)", bit_i, bit_i);
                    spike_count = spike_count + 1;
                end
            end
            if (spike_count == 0)
                $display("         [NONE] — spike pattern is all zeros! Check prepare_mnist.py.");
        end

        // ── Print a sample of the loaded weights ──────────────────────────
        $display("");
        $display("[INFO] Sample W[out][hid] entries from bank_memory:");
        $display("       W[0][10]  bank=%0d addr=0  value=%0d",
                 (0+10)%256, uut.weight_memory_inst.bank_memory[(0+10)%256][0]);
        $display("       W[0][11]  bank=%0d addr=0  value=%0d",
                 (0+11)%256, uut.weight_memory_inst.bank_memory[(0+11)%256][0]);
        $display("       W[0][50]  bank=%0d addr=0  value=%0d",
                 (0+50)%256, uut.weight_memory_inst.bank_memory[(0+50)%256][0]);
        $display("       W[9][50]  bank=%0d addr=9  value=%0d",
                 (9+50)%256, uut.weight_memory_inst.bank_memory[(9+50)%256][9]);

        // ── Print connection table sample ─────────────────────────────────
        $display("");
        $display("[INFO] Sample connection table entries:");
        $display("       connection_table[0][10]  = %02b  (expect 10)",
                 uut.connection_matrix_inst.connection_table[0][10]);
        $display("       connection_table[10][0]  = %02b  (expect 01)",
                 uut.connection_matrix_inst.connection_table[10][0]);
        $display("       connection_table[0][50]  = %02b  (expect 10)",
                 uut.connection_matrix_inst.connection_table[0][50]);

        // ── Enable and apply one timestep ─────────────────────────────────
        $display("");
        $display("[SIM] Enabling cluster and applying timestep 0 of image 0 …");
        global_cluster_enable = 1;
        @(posedge clock); @(posedge clock); #1;

        external_spike_input_bus = spike_patterns[0];
        $display("[SIM] t=%0t  external_spike_input_bus driven", $time);
        @(posedge clock);
        external_spike_input_bus = {NUM_NEURONS_PER_CLUSTER{1'b0}};
        #1;

        $display("[SIM] t=%0t  spike bus cleared.  cluster_busy_flag = %0b",
                 $time, cluster_busy_flag);

        // ── Wait and report ───────────────────────────────────────────────
        repeat(5) @(posedge clock); #1;
        $display("[SIM] t=%0t  After 5 cycles:  cluster_busy_flag = %0b  queue_empty = %0b",
                 $time, cluster_busy_flag,
                 uut.spike_queue_inst.queue_empty_flag);

        drain_stdp(STDP_WAIT_CYCLES);
        $display("[SIM] t=%0t  STDP drain complete.  waited %0d cycles.  busy = %0b",
                 $time, wait_cyc, cluster_busy_flag);

        // ── Apply all 20 timesteps to give LIF neurons the best chance ────
        $display("");
        $display("[SIM] Presenting all %0d timesteps of image 0 to accumulate LIF potential …",
                 TIMESTEPS_PER_IMG);

        begin : all_timesteps
            integer ts;
            for (ts = 1; ts < TIMESTEPS_PER_IMG; ts = ts + 1) begin
                external_spike_input_bus = spike_patterns[ts];
                @(posedge clock);
                external_spike_input_bus = {NUM_NEURONS_PER_CLUSTER{1'b0}};
                drain_stdp(STDP_WAIT_CYCLES);
                decay_enable_pulse = 1; @(posedge clock);
                decay_enable_pulse = 0; @(posedge clock); #1;
            end
        end

        // ── Final verdict ─────────────────────────────────────────────────
        $display("");
        $display("==========================================================");
        $display("  PIPELINE VERDICT AFTER IMAGE 0  (all %0d timesteps)", TIMESTEPS_PER_IMG);
        $display("");
        $display("  cluster_busy_flag        = %0b", cluster_busy_flag);
        $display("  queue_empty_flag         = %0b",
                 uut.spike_queue_inst.queue_empty_flag);
        $display("  dist_bus_valid (current) = %0b", uut.dist_bus_valid_wire);
        $display("  cluster_spike_output_bus = %0b", cluster_spike_output_bus[9:0]);
        $display("");
        $display("  Check the [DBG Sx] lines above for the first stage that");
        $display("  produced NO output — that is the broken stage.");
        $display("");
        $display("  Expected healthy transcript:");
        $display("    [DBG S1] queue_empty → LOW   (spikes captured by queue)");
        $display("    [DBG S1] dequeued neuron addr = <10..209>");
        $display("    [DBG S2] dist_bus VALID        (STDP distributing weights)");
        $display("    [DBG S3] receiver[0] captured  (weight reached LIF input)");
        $display("    [DBG S4] LIF[0] input_spike_wire HIGH");
        $display("    [DBG S5] *** OUTPUT NEURON x FIRED ***  (may need many images)");
        $display("==========================================================");
        $finish;
    end

endmodule
