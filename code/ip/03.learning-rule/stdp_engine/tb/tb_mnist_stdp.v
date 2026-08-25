// =============================================================================
// Testbench: tb_mnist_stdp
// End-to-end unsupervised STDP learning + inference on MNIST.
//
//   Phase 1 TRAIN  : learning on, homeostasis on. Weights self-organise into
//                    digit-like receptive fields via STDP + WTA.
//   Phase 2 ASSIGN : learning off. Each excitatory neuron is labelled with the
//                    digit it responds to most strongly (per-class mean rate).
//   Phase 3 TEST   : learning off. Predict argmax over per-class mean response.
//
// Prints overall accuracy, per-digit accuracy and a confusion matrix.
// =============================================================================

`timescale 1ns/1ps

module tb_mnist_stdp;

    `include "mnist_config.vh"

    // ---- run split (must sum to N_IMAGES) ----
    parameter N_TRAIN  = (N_IMAGES * 60) / 100;
    parameter N_ASSIGN = (N_IMAGES * 20) / 100;
    parameter N_TEST   = N_IMAGES - N_TRAIN - N_ASSIGN;

    parameter CLK_PERIOD_NS   = 10;
        parameter DRAIN_LIMIT     = 20000;   // cycles per timestep
    // Decay ticks per timestep. The pre-synaptic trace halves on every tick
    // (DECAY_SHIFT_LOG2=0), so this sets the STDP causal window:
    //   8 ticks -> 255>>8 == 0, so a pre spike is worth +31 in its OWN
    //   timestep and nothing afterwards. Anything wider potentiates synapses
    //   that merely fired "recently", every synapse ends up saturated at 255,
    //   and a neuron with all-255 weights wins every image regardless of digit
    //   -- a generic detector with no selectivity at all.
    parameter DECAY_TICKS_PER_STEP = 8;
    parameter NUM_CLASSES     = 10;

    // ---- STDP / neuron tuning ----
    parameter LTP_SHIFT_AMOUNT   = 3;    // LTP step = pre_trace  >> 3   (max +31)
    parameter LTD_SHIFT_AMOUNT   = 5;    // LTD step = post_trace >> 5   (max  -7)
    // Equilibrium: a synapse survives only if its pre-neuron fires in the same
    // timestep as the post-spike with probability > LTD/(LTP+LTD) = 7/38 ~ 0.18.
    // Stroke pixels clear that bar, background pixels do not -- that is what
    // carves the receptive field.
    parameter MEMBRANE_LEAK_SHIFT= 4;
    parameter REFRACTORY_CYCLES  = 8;
    parameter THETA_INCREMENT    = 1200;
    parameter THETA_DECAY_SHIFT  = 7;
    parameter WTA_INHIBIT_CYCLES = 8;

    reg clock = 0;
    reg reset, global_cluster_enable, learning_enable, adaptation_enable;
    reg membrane_clear, decay_enable_pulse;
    reg [NUM_NEURONS_PER_CLUSTER-1:0] external_spike_input_bus;

    wire [NUM_NEURONS_PER_CLUSTER-1:0] cluster_spike_output_bus;
    wire cluster_busy_flag, queue_overflow_flag, transaction_timeout_flag;

    neuron_cluster #(
        .NUM_NEURONS_PER_CLUSTER   (NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH      (NEURON_ADDRESS_WIDTH),
        .NUM_WEIGHT_BANKS          (NUM_NEURONS_PER_CLUSTER),
        .WEIGHT_BANK_ADDRESS_WIDTH (NEURON_ADDRESS_WIDTH),
        .WEIGHT_BIT_WIDTH          (8),
        .TRACE_VALUE_BIT_WIDTH     (8),
        .DECAY_TIMER_BIT_WIDTH     (12),
        .TRACE_SATURATION_THRESHOLD(256),
        .DECAY_SHIFT_LOG2          (0),      // trace halves every decay tick
        .TRACE_INCREMENT_VALUE     (32),
        .NUM_TRACE_UPDATE_MODULES  (4),
        .SPIKE_QUEUE_DEPTH         (NUM_NEURONS_PER_CLUSTER),
        .LTP_SHIFT_AMOUNT          (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT          (LTD_SHIFT_AMOUNT),
        .INCREASE_MODE             (0),
        .MEMBRANE_BIT_WIDTH        (20),
        .BASE_THRESHOLD            (BASE_THRESHOLD),
        .MEMBRANE_LEAK_SHIFT       (MEMBRANE_LEAK_SHIFT),
        .REFRACTORY_CYCLES         (REFRACTORY_CYCLES),
        .THETA_INCREMENT           (THETA_INCREMENT),
        .THETA_DECAY_SHIFT         (THETA_DECAY_SHIFT),
        .WTA_GROUP_START           (EXC_START),
        .WTA_GROUP_END             (EXC_END),
        .WTA_ENABLE                (1),
        .WTA_INHIBIT_CYCLES        (WTA_INHIBIT_CYCLES)
    ) uut (
        .clock                   (clock),
        .reset                   (reset),
        .global_cluster_enable   (global_cluster_enable),
        .learning_enable         (learning_enable),
        .adaptation_enable       (adaptation_enable),
        .membrane_clear          (membrane_clear),
        .decay_enable_pulse      (decay_enable_pulse),
        .external_spike_input_bus(external_spike_input_bus),
        .cluster_spike_output_bus(cluster_spike_output_bus),
        .cluster_busy_flag       (cluster_busy_flag),
        .queue_overflow_flag     (queue_overflow_flag),
        .transaction_timeout_flag(transaction_timeout_flag)
    );

    always #(CLK_PERIOD_NS/2) clock = ~clock;

    // =========================================================================
    // Data
    // =========================================================================
    reg [NUM_NEURONS_PER_CLUSTER-1:0] spike_patterns [0:N_IMAGES*TIMESTEPS_PER_IMG-1];
    reg [3:0]                         image_labels   [0:N_IMAGES-1];
    reg [7:0]                         flat_weights   [0:NUM_NEURONS_PER_CLUSTER*BANK_DEPTH-1];

    // =========================================================================
    // Live excitatory spike counter (spikes are 1-cycle pulses)
    // =========================================================================
    reg     counting_enable;
    integer exc_spike_count [0:NUM_EXC-1];
    integer count_idx;
    integer total_spikes_observed;

    always @(posedge clock) begin
        if (counting_enable) begin
            for (count_idx = 0; count_idx < NUM_EXC; count_idx = count_idx + 1) begin
                if (cluster_spike_output_bus[EXC_START + count_idx]) begin
                    exc_spike_count[count_idx] = exc_spike_count[count_idx] + 1;
                    total_spikes_observed      = total_spikes_observed + 1;
                end
            end
        end
    end

    // =========================================================================
    // Statistics
    // =========================================================================
    integer class_response  [0:NUM_EXC*NUM_CLASSES-1]; // exc*10 + digit
    integer class_image_count[0:NUM_CLASSES-1];
    integer neuron_label    [0:NUM_EXC-1];
    integer neurons_per_class[0:NUM_CLASSES-1];
    integer confusion       [0:NUM_CLASSES*NUM_CLASSES-1]; // true*10 + predicted
    integer per_digit_correct[0:NUM_CLASSES-1];
    integer per_digit_total  [0:NUM_CLASSES-1];

    integer img_i, t_i, e_i, d_i, k_i, bk, ad;
    integer drain_cycles, drain_timeouts;
    integer n_correct, n_tested, predicted, true_label;
    integer best_val, best_idx;
    real    score, best_score, accuracy_pct;
    integer active_neurons;

    // =========================================================================
    // Tasks
    // =========================================================================
    task drain;
        begin
            drain_cycles = 0;
            while (cluster_busy_flag && drain_cycles < DRAIN_LIMIT) begin
                @(posedge clock);
                drain_cycles = drain_cycles + 1;
            end
            if (drain_cycles >= DRAIN_LIMIT) drain_timeouts = drain_timeouts + 1;
            #1;
        end
    endtask

    task clear_membranes;
        begin
            membrane_clear = 1;
            @(posedge clock); @(posedge clock);
            membrane_clear = 0;
            @(posedge clock); #1;
        end
    endtask

    task run_image;
        input integer idx;
        begin
            for (e_i = 0; e_i < NUM_EXC; e_i = e_i + 1)
                exc_spike_count[e_i] = 0;

            clear_membranes();

            for (t_i = 0; t_i < TIMESTEPS_PER_IMG; t_i = t_i + 1) begin
                external_spike_input_bus = spike_patterns[idx*TIMESTEPS_PER_IMG + t_i];
                @(posedge clock); #1;
                external_spike_input_bus = {NUM_NEURONS_PER_CLUSTER{1'b0}};
                drain();

                // Decay ticks: leak membranes, decay theta, advance the global
                // trace timestamp (see DECAY_TICKS_PER_STEP).
                //
                // NOTE the #1 after each posedge. Deasserting a stimulus in the
                // same delta as the clock edge races the DUT's own @(posedge)
                // block. Without it the global decay timer never saw a single
                // pulse: delta_t stayed 0, no trace ever decayed, every synapse
                // whose input had EVER fired kept pre_trace = 255 and so kept
                // receiving LTP, and all weights saturated at 255. The layer
                // then degenerated into identical "any input" detectors.
                for (k_i = 0; k_i < DECAY_TICKS_PER_STEP; k_i = k_i + 1) begin
                    decay_enable_pulse = 1;
                    @(posedge clock); #1;
                    decay_enable_pulse = 0;
                    @(posedge clock); #1;
                end
                drain();
            end
        end
    endtask

    // Dump one excitatory neuron's learned receptive field as ASCII art.
    // W(pre=p, post=e) lives at bank_memory[(e+p) mod N][e].
    integer rf_r, rf_c, rf_p, rf_w, rf_sum;
    task dump_receptive_field;
        input integer e;
        begin
            rf_sum = 0;
            for (rf_p = 0; rf_p < NUM_INPUT; rf_p = rf_p + 1)
                rf_sum = rf_sum +
                    uut.weight_memory_inst.bank_memory[(e + rf_p) % NUM_NEURONS_PER_CLUSTER][e];
            $display("    neuron %0d  (label %0d, mean weight %0d)",
                     e, neuron_label[e - EXC_START], rf_sum / NUM_INPUT);
            for (rf_r = 0; rf_r < GRID; rf_r = rf_r + 1) begin
                $write("      ");
                for (rf_c = 0; rf_c < GRID; rf_c = rf_c + 1) begin
                    rf_p = rf_r*GRID + rf_c;
                    rf_w = uut.weight_memory_inst.bank_memory[(e + rf_p) % NUM_NEURONS_PER_CLUSTER][e];
                    if      (rf_w > 200) $write("##");
                    else if (rf_w > 140) $write("++");
                    else if (rf_w >  80) $write("..");
                    else if (rf_w >  30) $write("' ");
                    else                 $write("  ");
                end
                $write("\n");
            end
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("================================================================");
        $display("  STDP NEUROMORPHIC ACCELERATOR - MNIST");
        $display("----------------------------------------------------------------");
        $display("  cluster neurons : %0d", NUM_NEURONS_PER_CLUSTER);
        $display("  input layer     : %0d  (%0dx%0d, neurons 0..%0d)",
                 NUM_INPUT, GRID, GRID, NUM_INPUT-1);
        $display("  excitatory layer: %0d  (neurons %0d..%0d, WTA)",
                 NUM_EXC, EXC_START, EXC_END);
        $display("  synapses learned: %0d", NUM_INPUT*NUM_EXC);
        $display("  timesteps/image : %0d", TIMESTEPS_PER_IMG);
        $display("  base threshold  : %0d", BASE_THRESHOLD);
        $display("  LTP/LTD shift   : %0d / %0d", LTP_SHIFT_AMOUNT, LTD_SHIFT_AMOUNT);
        $display("  images          : %0d train / %0d assign / %0d test",
                 N_TRAIN, N_ASSIGN, N_TEST);
        $display("================================================================");

        $readmemh("mnist_spikes.hex",  spike_patterns);
        $readmemh("mnist_labels.hex",  image_labels);
        $readmemh("init_weights.hex",  flat_weights);

        reset                    = 1;
        global_cluster_enable    = 0;
        learning_enable          = 0;
        adaptation_enable        = 0;
        membrane_clear           = 0;
        decay_enable_pulse       = 0;
        external_spike_input_bus = 0;
        counting_enable          = 0;
        total_spikes_observed    = 0;
        drain_timeouts           = 0;
        repeat(6) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        // ---- program weight memory ----
        for (bk = 0; bk < NUM_NEURONS_PER_CLUSTER; bk = bk + 1)
            for (ad = 0; ad < BANK_DEPTH; ad = ad + 1)
                uut.weight_memory_inst.bank_memory[bk][ad] =
                    flat_weights[bk*BANK_DEPTH + ad];

        // ---- program connectivity: every input -> every excitatory ----
        for (e_i = EXC_START; e_i <= EXC_END; e_i = e_i + 1)
            for (k_i = 0; k_i < NUM_INPUT; k_i = k_i + 1) begin
                // k_i is PRE-synaptic to e_i  -> drives LTP/LTD when e_i fires
                uut.connection_matrix_inst.input_connection_rows[e_i][k_i]  = 1'b1;
                // k_i drives e_i -> weight distribution when k_i fires
                uut.connection_matrix_inst.output_connection_rows[k_i][e_i] = 1'b1;
            end
        @(posedge clock); #1;

        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
            class_image_count[d_i]  = 0;
            neurons_per_class[d_i]  = 0;
            per_digit_correct[d_i]  = 0;
            per_digit_total[d_i]    = 0;
        end
        for (k_i = 0; k_i < NUM_EXC*NUM_CLASSES; k_i = k_i + 1) class_response[k_i] = 0;
        for (k_i = 0; k_i < NUM_CLASSES*NUM_CLASSES; k_i = k_i + 1) confusion[k_i] = 0;

        global_cluster_enable = 1;
        counting_enable       = 1;
        repeat(2) @(posedge clock); #1;

        // ==================================================================
        // PHASE 1 - TRAIN
        // ==================================================================
        $display("");
        $display("--- Phase 1: unsupervised STDP training (%0d images) ---", N_TRAIN);
        learning_enable   = 1;
        adaptation_enable = 1;

        for (img_i = 0; img_i < N_TRAIN; img_i = img_i + 1) begin
            run_image(img_i);
            if ((img_i+1) % 50 == 0)
                $display("  [train] %4d / %0d    exc spikes: %0d   t=%0t  drainTO=%0d",
                         img_i+1, N_TRAIN, total_spikes_observed, $time, drain_timeouts);
        end
        $display("  training done. total excitatory spikes: %0d", total_spikes_observed);

        if (total_spikes_observed == 0) begin
            $display("");
            $display("  ERROR: no excitatory neuron ever fired.");
            $display("  Lower --base-threshold or raise --init-weight-* in");
            $display("  tools/prepare_mnist_stdp.py and re-run.");
            $display("");
        end

        // ==================================================================
        // PHASE 2 - ASSIGN LABELS
        // ==================================================================
        $display("");
        $display("--- Phase 2: neuron label assignment (%0d images) ---", N_ASSIGN);
        // Only WEIGHT learning is frozen. The adaptive threshold keeps
        // running: with it frozen, whichever neuron happened to end training
        // with a low theta monopolises the layer during inference.
        learning_enable   = 0;
        adaptation_enable = 1;

        for (img_i = N_TRAIN; img_i < N_TRAIN + N_ASSIGN; img_i = img_i + 1) begin
            run_image(img_i);
            true_label = image_labels[img_i];
            class_image_count[true_label] = class_image_count[true_label] + 1;
            for (e_i = 0; e_i < NUM_EXC; e_i = e_i + 1)
                class_response[e_i*NUM_CLASSES + true_label] =
                    class_response[e_i*NUM_CLASSES + true_label] + exc_spike_count[e_i];
        end

        // each neuron takes the digit with the highest MEAN response
        active_neurons = 0;
        for (e_i = 0; e_i < NUM_EXC; e_i = e_i + 1) begin
            best_score = -1.0;
            best_idx   = -1;
            for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
                if (class_image_count[d_i] > 0) begin
                    score = 1.0 * class_response[e_i*NUM_CLASSES + d_i] / class_image_count[d_i];
                    if (score > best_score) begin
                        best_score = score;
                        best_idx   = d_i;
                    end
                end
            end
            if (best_score > 0.0) begin
                neuron_label[e_i] = best_idx;
                neurons_per_class[best_idx] = neurons_per_class[best_idx] + 1;
                active_neurons = active_neurons + 1;
            end else begin
                neuron_label[e_i] = -1;   // never responded: excluded from voting
            end
        end

        $display("  neurons that responded: %0d / %0d", active_neurons, NUM_EXC);
        $write("  spikes per neuron    :");
        for (e_i = 0; e_i < NUM_EXC; e_i = e_i + 1) begin
            best_val = 0;
            for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
                best_val = best_val + class_response[e_i*NUM_CLASSES + d_i];
            $write(" %0d", best_val);
        end
        $write("\n");
        $write("  neurons per digit    :");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
            $write("  %0d:%0d", d_i, neurons_per_class[d_i]);
        $write("\n");

        $display("");
        $display("--- Learned receptive fields (weights read back from bank_memory) ---");
        for (k_i = 0; k_i < NUM_EXC && k_i < 6; k_i = k_i + 1)
            dump_receptive_field(EXC_START + k_i);

        // ==================================================================
        // PHASE 3 - TEST
        // ==================================================================
        $display("");
        $display("--- Phase 3: inference (%0d images) ---", N_TEST);
        n_correct = 0;
        n_tested  = 0;

        for (img_i = N_TRAIN + N_ASSIGN; img_i < N_IMAGES; img_i = img_i + 1) begin
            run_image(img_i);

            // per-class mean firing rate over the neurons assigned to it
            best_score = -1.0;
            predicted  = -1;
            for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
                if (neurons_per_class[d_i] > 0) begin
                    best_val = 0;
                    for (e_i = 0; e_i < NUM_EXC; e_i = e_i + 1)
                        if (neuron_label[e_i] == d_i)
                            best_val = best_val + exc_spike_count[e_i];
                    score = 1.0 * best_val / neurons_per_class[d_i];
                    if (score > best_score) begin
                        best_score = score;
                        predicted  = d_i;
                    end
                end
            end

            true_label = image_labels[img_i];
            per_digit_total[true_label] = per_digit_total[true_label] + 1;
            if (predicted >= 0)
                confusion[true_label*NUM_CLASSES + predicted] =
                    confusion[true_label*NUM_CLASSES + predicted] + 1;
            if (predicted == true_label) begin
                n_correct = n_correct + 1;
                per_digit_correct[true_label] = per_digit_correct[true_label] + 1;
            end
            n_tested = n_tested + 1;

            if (n_tested % 25 == 0) begin
                accuracy_pct = 100.0 * n_correct / n_tested;
                $display("  [test] %4d / %0d    correct: %0d    accuracy: %0.1f%%",
                         n_tested, N_TEST, n_correct, accuracy_pct);
            end
        end

        // ==================================================================
        // RESULTS
        // ==================================================================
        accuracy_pct = (n_tested > 0) ? 100.0 * n_correct / n_tested : 0.0;
        $display("");
        $display("================================================================");
        $display("  RESULTS");
        $display("----------------------------------------------------------------");
        $display("  Test images        : %0d", n_tested);
        $display("  Correct            : %0d", n_correct);
        $display("  ACCURACY           : %0.2f %%", accuracy_pct);
        $display("  Random baseline    : 10.00 %%");
        $display("");
        $display("  Per-digit accuracy:");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
            if (per_digit_total[d_i] > 0)
                $display("    digit %0d : %3d / %3d   (%0.1f%%)",
                         d_i, per_digit_correct[d_i], per_digit_total[d_i],
                         100.0*per_digit_correct[d_i]/per_digit_total[d_i]);
        $display("");
        $display("  Confusion matrix (rows = true, cols = predicted):");
        $write("        ");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) $write("%4d", d_i);
        $write("\n");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
            $write("    %0d : ", d_i);
            for (k_i = 0; k_i < NUM_CLASSES; k_i = k_i + 1)
                $write("%4d", confusion[d_i*NUM_CLASSES + k_i]);
            $write("\n");
        end
        $display("");
        $display("  Health: excitatory spikes=%0d  drain timeouts=%0d  queue overflow=%0b  stdp timeout=%0b",
                 total_spikes_observed, drain_timeouts,
                 queue_overflow_flag, transaction_timeout_flag);
        $display("================================================================");
        $finish;
    end

endmodule
