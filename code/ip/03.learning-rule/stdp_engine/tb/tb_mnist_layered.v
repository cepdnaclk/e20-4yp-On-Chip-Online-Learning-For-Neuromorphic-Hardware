// =============================================================================
// Testbench: tb_mnist_layered   (architecture B)
// Two-layer multi-cluster MNIST with real intermediate neurons.
//
//   5 clusters x 64 neurons, uniform local address map in every cluster:
//       local  0..31   axons
//       local 32..63   neurons (the WTA group)
//
//   Layer 1  clusters 0..3   axons 0..24  = one 5x5 quadrant of the image
//                            neurons 32..39 = 8 excitatory   -> 32 hidden
//   Layer 2  cluster 4       axons 0..31  = one per hidden neuron, delivered
//                                           by spike_router
//                            neurons 32..63 = 32 output neurons
//
//   Layer-1 hidden neuron (cluster c, local 32+k)
//        --router-->  cluster 4, axon c*L1_NEURONS + k
//
// Phases: TRAIN (STDP on) -> ASSIGN (label each output neuron) -> TEST.
// Prints accuracy, per-digit accuracy, a confusion matrix, layer-1 receptive
// fields (5x5 patches read out of bank_memory) and hidden/output activity.
// =============================================================================

`timescale 1ns/1ps

module tb_mnist_layered;

    `include "mnist_config_layered.vh"

    parameter N_TRAIN  = (N_IMAGES * 60) / 100;
    parameter N_ASSIGN = (N_IMAGES * 20) / 100;
    parameter N_TEST   = N_IMAGES - N_TRAIN - N_ASSIGN;

    parameter CLK_PERIOD           = 10;
    parameter DRAIN_LIMIT          = 40000;
    parameter DECAY_TICKS_PER_STEP = 8;
    parameter NUM_CLASSES          = 10;

    // learning-rule constants (array-wide)
    parameter LTP_SHIFT_AMOUNT    = 3;
    parameter LTD_SHIFT_AMOUNT    = 5;
    parameter MEMBRANE_LEAK_SHIFT = 4;
    parameter REFRACTORY_CYCLES   = 8;
    parameter THETA_INCREMENT     = 900;
    // layer 2 sees ~1.5 spikes/timestep vs layer 1's ~3.3, so it needs its own
    // excitability -- otherwise it fires ~0.5 times per image and learns nothing
    parameter BASE_THRESHOLD_L2   = 300;
    parameter THETA_INCREMENT_L2  = 400;
    parameter THETA_DECAY_SHIFT   = 7;
    parameter WTA_INHIBIT_CYCLES  = 8;

    parameter W_INIT_MIN    = 40;
    parameter W_INIT_MAX    = 90;
    parameter W_INIT_MIN_L2 = 120;   // layer 2 has fewer, sparser inputs
    parameter W_INIT_MAX_L2 = 200;

    reg clock = 0;
    reg reset, gce, learn_en, adapt_en, mclear, decay_pulse, router_en;
    reg [TOTAL_NEURONS-1:0] ext_in;

    wire [TOTAL_NEURONS-1:0] spikes;
    wire busy, q_ovf, txn_to, rtr_ovf;

    neuron_cluster_array #(
        .NUM_CLUSTERS             (NUM_CLUSTERS),
        .NUM_NEURONS_PER_CLUSTER  (NUM_NEURONS_PER_CLUSTER),
        .ROUTER_FIFO_DEPTH        (64),
        .DECAY_SHIFT_LOG2         (0),
        .NUM_TRACE_UPDATE_MODULES (4),
        .LTP_SHIFT_AMOUNT         (LTP_SHIFT_AMOUNT),
        .LTD_SHIFT_AMOUNT         (LTD_SHIFT_AMOUNT),
        .MEMBRANE_BIT_WIDTH       (20),
        .BASE_THRESHOLD           (BASE_THRESHOLD),
        .MEMBRANE_LEAK_SHIFT      (MEMBRANE_LEAK_SHIFT),
        .REFRACTORY_CYCLES        (REFRACTORY_CYCLES),
        .THETA_INCREMENT          (THETA_INCREMENT),
        .THETA_DECAY_SHIFT        (THETA_DECAY_SHIFT),
        .CLUSTER_SPLIT_INDEX      (L2_CLUSTER),
        .BASE_THRESHOLD_UPPER     (BASE_THRESHOLD_L2),
        .THETA_INCREMENT_UPPER    (THETA_INCREMENT_L2),
        .WTA_GROUP_START          (NEURON_BASE),
        .WTA_GROUP_END            (NUM_NEURONS_PER_CLUSTER-1),
        .WTA_ENABLE               (1),
        .WTA_INHIBIT_CYCLES       (WTA_INHIBIT_CYCLES)
    ) uut (
        .clock                    (clock),
        .reset                    (reset),
        .global_cluster_enable    (gce),
        .learning_enable          (learn_en),
        .adaptation_enable        (adapt_en),
        .membrane_clear           (mclear),
        .decay_enable_pulse       (decay_pulse),
        .router_enable            (router_en),
        .external_spike_input_bus (ext_in),
        .cluster_spike_output_bus (spikes),
        .array_busy_flag          (busy),
        .queue_overflow_flag      (q_ovf),
        .transaction_timeout_flag (txn_to),
        .router_overflow_flag     (rtr_ovf)
    );

    always #(CLK_PERIOD/2) clock = ~clock;

    // =========================================================================
    // Per-cluster configuration. Icarus cannot index a generate scope with a
    // runtime variable, so this lives in a genvar loop released by cfg_go.
    // =========================================================================
    reg cfg_go = 1'b0;

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CLUSTERS; gc = gc + 1) begin : cfgblk
            integer a, n, rs;
            initial begin
                wait (cfg_go === 1'b1);
                rs = 32'h1234_0000 + gc;   // per-cluster deterministic seed

                if (gc < L1_CLUSTERS) begin
                    // ---- LAYER 1: quadrant pixels -> 8 excitatory neurons ----
                    for (a = 0; a < L1_AXONS; a = a + 1) begin
                        for (n = 0; n < L1_NEURONS; n = n + 1) begin
                            uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                                .output_connection_rows[AXON_BASE+a][NEURON_BASE+n] = 1'b1;
                            uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                                .input_connection_rows [NEURON_BASE+n][AXON_BASE+a] = 1'b1;
                            uut.gen_clusters[gc].cluster_inst.weight_memory_inst
                                .bank_memory[(NEURON_BASE+n + AXON_BASE+a) % NUM_NEURONS_PER_CLUSTER]
                                            [NEURON_BASE+n]
                                = W_INIT_MIN + ({$random(rs)} % (W_INIT_MAX-W_INIT_MIN+1));
                        end
                    end
                end else begin
                    // ---- LAYER 2: hidden neurons -> 32 output neurons ----
                    for (a = 0; a < L2_AXONS; a = a + 1) begin
                        for (n = 0; n < L2_NEURONS; n = n + 1) begin
                            uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                                .output_connection_rows[AXON_BASE+a][NEURON_BASE+n] = 1'b1;
                            uut.gen_clusters[gc].cluster_inst.connection_matrix_inst
                                .input_connection_rows [NEURON_BASE+n][AXON_BASE+a] = 1'b1;
                            uut.gen_clusters[gc].cluster_inst.weight_memory_inst
                                .bank_memory[(NEURON_BASE+n + AXON_BASE+a) % NUM_NEURONS_PER_CLUSTER]
                                            [NEURON_BASE+n]
                                = W_INIT_MIN_L2 + ({$random(rs)} % (W_INIT_MAX_L2-W_INIT_MIN_L2+1));
                        end
                    end
                end
            end
        end
    endgenerate

    // =========================================================================
    // Data
    // =========================================================================
    reg [TOTAL_NEURONS-1:0] spike_patterns [0:N_IMAGES*TIMESTEPS_PER_IMG-1];
    reg [3:0]               image_labels   [0:N_IMAGES-1];

    // =========================================================================
    // Live spike counters
    // =========================================================================
    integer out_spikes    [0:L2_NEURONS-1];      // per image, layer 2
    integer hidden_spikes [0:63];                // per image, layer 1 (flat)
    integer total_hidden, total_out;
    integer sc_i;
    reg     count_en;

    always @(posedge clock) begin
        if (count_en) begin
            for (sc_i = 0; sc_i < L2_NEURONS; sc_i = sc_i + 1)
                if (spikes[L2_CLUSTER*NUM_NEURONS_PER_CLUSTER + NEURON_BASE + sc_i]) begin
                    out_spikes[sc_i] = out_spikes[sc_i] + 1;
                    total_out        = total_out + 1;
                end
            for (sc_i = 0; sc_i < L1_CLUSTERS*L1_NEURONS; sc_i = sc_i + 1)
                if (spikes[(sc_i / L1_NEURONS)*NUM_NEURONS_PER_CLUSTER +
                            NEURON_BASE + (sc_i % L1_NEURONS)]) begin
                    hidden_spikes[sc_i] = hidden_spikes[sc_i] + 1;
                    total_hidden        = total_hidden + 1;
                end
        end
    end

    // =========================================================================
    // Statistics
    // =========================================================================
    integer class_response   [0:32*NUM_CLASSES-1];
    integer class_image_count[0:NUM_CLASSES-1];
    integer neuron_label     [0:31];
    integer neurons_per_class[0:NUM_CLASSES-1];
    integer confusion        [0:NUM_CLASSES*NUM_CLASSES-1];
    integer per_digit_correct[0:NUM_CLASSES-1];
    integer per_digit_total  [0:NUM_CLASSES-1];

    integer img_i, t_i, o_i, d_i, k_i, g, c, guard;
    integer n_correct, n_tested, predicted, true_label, best_val, active_neurons;
    real    score, best_score, accuracy_pct;

    task drain;
        begin
            guard = 0;
            while (busy && guard < DRAIN_LIMIT) begin @(posedge clock); guard = guard + 1; end
            #1;
        end
    endtask

    task clear_membranes;
        begin
            mclear = 1; @(posedge clock); #1; @(posedge clock); #1;
            mclear = 0; @(posedge clock); #1;
        end
    endtask

    task run_image;
        input integer idx;
        begin
            for (o_i = 0; o_i < L2_NEURONS; o_i = o_i + 1) out_spikes[o_i] = 0;
            for (o_i = 0; o_i < L1_CLUSTERS*L1_NEURONS; o_i = o_i + 1) hidden_spikes[o_i] = 0;

            clear_membranes();

            for (t_i = 0; t_i < TIMESTEPS_PER_IMG; t_i = t_i + 1) begin
                ext_in = spike_patterns[idx*TIMESTEPS_PER_IMG + t_i];
                @(posedge clock); #1;
                ext_in = {TOTAL_NEURONS{1'b0}};
                drain();

                // NOTE the #1 after each posedge: deasserting in the same delta
                // as the clock edge races the DUT and the decay timer never
                // advances (see DIAGNOSIS.md defect 17).
                for (k_i = 0; k_i < DECAY_TICKS_PER_STEP; k_i = k_i + 1) begin
                    decay_pulse = 1; @(posedge clock); #1;
                    decay_pulse = 0; @(posedge clock); #1;
                end
                drain();
            end
        end
    endtask

    // layer-1 receptive field as a 5x5 patch
    integer rf_r, rf_c, rf_a, rf_w;
    task dump_l1_rf;
        input integer cluster;
        input integer neuron_k;
        begin
            $display("    L1 cluster %0d neuron %0d (quadrant %0d):",
                     cluster, neuron_k, cluster);
            for (rf_r = 0; rf_r < 5; rf_r = rf_r + 1) begin
                $write("      ");
                for (rf_c = 0; rf_c < 5; rf_c = rf_c + 1) begin
                    rf_a = rf_r*5 + rf_c;
                    case (cluster)
                      0: rf_w = uut.gen_clusters[0].cluster_inst.weight_memory_inst
                                  .bank_memory[(NEURON_BASE+neuron_k + rf_a) % NUM_NEURONS_PER_CLUSTER][NEURON_BASE+neuron_k];
                      1: rf_w = uut.gen_clusters[1].cluster_inst.weight_memory_inst
                                  .bank_memory[(NEURON_BASE+neuron_k + rf_a) % NUM_NEURONS_PER_CLUSTER][NEURON_BASE+neuron_k];
                      2: rf_w = uut.gen_clusters[2].cluster_inst.weight_memory_inst
                                  .bank_memory[(NEURON_BASE+neuron_k + rf_a) % NUM_NEURONS_PER_CLUSTER][NEURON_BASE+neuron_k];
                      default: rf_w = uut.gen_clusters[3].cluster_inst.weight_memory_inst
                                  .bank_memory[(NEURON_BASE+neuron_k + rf_a) % NUM_NEURONS_PER_CLUSTER][NEURON_BASE+neuron_k];
                    endcase
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
    initial begin
        $display("================================================================");
        $display("  TWO-LAYER MULTI-CLUSTER SNN  -  MNIST");
        $display("----------------------------------------------------------------");
        $display("  clusters        : %0d x %0d neurons = %0d slots",
                 NUM_CLUSTERS, NUM_NEURONS_PER_CLUSTER, TOTAL_NEURONS);
        $display("  input           : %0d px (10x10), %0d per L1 cluster",
                 GRID*GRID, L1_AXONS);
        $display("  hidden (layer 1): %0d  (%0d clusters x %0d, WTA per cluster)",
                 L1_CLUSTERS*L1_NEURONS, L1_CLUSTERS, L1_NEURONS);
        $display("  output (layer 2): %0d  (cluster %0d, WTA)", L2_NEURONS, L2_CLUSTER);
        $display("  plastic synapses: %0d",
                 L1_CLUSTERS*L1_AXONS*L1_NEURONS + L2_AXONS*L2_NEURONS);
        $display("  images          : %0d train / %0d assign / %0d test",
                 N_TRAIN, N_ASSIGN, N_TEST);
        $display("================================================================");

        $readmemh("mnist_spikes.hex", spike_patterns);
        $readmemh("mnist_labels.hex", image_labels);

        reset = 1; gce = 0; learn_en = 0; adapt_en = 0;
        mclear = 0; decay_pulse = 0; router_en = 0; count_en = 0;
        ext_in = {TOTAL_NEURONS{1'b0}};
        total_hidden = 0; total_out = 0;
        repeat (6) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        cfg_go = 1'b1;
        #1;

        // ---- routing table: L1 hidden neuron -> L2 axon ----
        for (c = 0; c < L1_CLUSTERS; c = c + 1) begin
            for (k_i = 0; k_i < L1_NEURONS; k_i = k_i + 1) begin
                g = c*NUM_NEURONS_PER_CLUSTER + NEURON_BASE + k_i;
                uut.router_inst.route_valid[g]             = 1'b1;
                uut.router_inst.route_dest_cluster_mask[g] = (1 << L2_CLUSTER);
                uut.router_inst.route_dest_axon[g]         = AXON_BASE + c*L1_NEURONS + k_i;
            end
        end
        @(posedge clock); #1;

        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
            class_image_count[d_i] = 0;
            neurons_per_class[d_i] = 0;
            per_digit_correct[d_i] = 0;
            per_digit_total[d_i]   = 0;
        end
        for (k_i = 0; k_i < 32*NUM_CLASSES; k_i = k_i + 1) class_response[k_i] = 0;
        for (k_i = 0; k_i < NUM_CLASSES*NUM_CLASSES; k_i = k_i + 1) confusion[k_i] = 0;

        gce = 1; router_en = 1; count_en = 1;
        repeat (2) @(posedge clock); #1;

        // ==================================================================
        $display("");
        $display("--- Phase 1: unsupervised STDP training (%0d images) ---", N_TRAIN);
        learn_en = 1; adapt_en = 1;
        for (img_i = 0; img_i < N_TRAIN; img_i = img_i + 1) begin
            run_image(img_i);
            if ((img_i+1) % 100 == 0)
                $display("  [train] %4d / %0d   hidden spikes: %0d   output spikes: %0d",
                         img_i+1, N_TRAIN, total_hidden, total_out);
        end
        $display("  training done. hidden spikes: %0d   output spikes: %0d",
                 total_hidden, total_out);

        if (total_hidden == 0)
            $display("  ERROR: layer 1 never fired - lower BASE_THRESHOLD.");
        else if (total_out == 0)
            $display("  ERROR: layer 2 never fired - layer 1 output too sparse for the shared threshold.");

        // ==================================================================
        $display("");
        $display("--- Phase 2: output-neuron label assignment (%0d images) ---", N_ASSIGN);
        learn_en = 0; adapt_en = 1;
        for (img_i = N_TRAIN; img_i < N_TRAIN + N_ASSIGN; img_i = img_i + 1) begin
            run_image(img_i);
            true_label = image_labels[img_i];
            class_image_count[true_label] = class_image_count[true_label] + 1;
            for (o_i = 0; o_i < L2_NEURONS; o_i = o_i + 1)
                class_response[o_i*NUM_CLASSES + true_label] =
                    class_response[o_i*NUM_CLASSES + true_label] + out_spikes[o_i];
        end

        active_neurons = 0;
        for (o_i = 0; o_i < L2_NEURONS; o_i = o_i + 1) begin
            best_score = -1.0; best_val = -1;
            for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
                if (class_image_count[d_i] > 0) begin
                    score = 1.0 * class_response[o_i*NUM_CLASSES + d_i] / class_image_count[d_i];
                    if (score > best_score) begin best_score = score; best_val = d_i; end
                end
            if (best_score > 0.0) begin
                neuron_label[o_i] = best_val;
                neurons_per_class[best_val] = neurons_per_class[best_val] + 1;
                active_neurons = active_neurons + 1;
            end else
                neuron_label[o_i] = -1;
        end
        $display("  output neurons that responded: %0d / %0d", active_neurons, L2_NEURONS);
        $write("  neurons per digit :");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
            $write("  %0d:%0d", d_i, neurons_per_class[d_i]);
        $write("\n");

        $display("");
        $display("--- Layer-1 receptive fields (5x5 quadrant patches) ---");
        for (c = 0; c < L1_CLUSTERS; c = c + 1) dump_l1_rf(c, 0);

        // ==================================================================
        $display("");
        $display("--- Phase 3: inference (%0d images) ---", N_TEST);
        n_correct = 0; n_tested = 0;
        for (img_i = N_TRAIN + N_ASSIGN; img_i < N_IMAGES; img_i = img_i + 1) begin
            run_image(img_i);
            best_score = -1.0; predicted = -1;
            for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
                if (neurons_per_class[d_i] > 0) begin
                    best_val = 0;
                    for (o_i = 0; o_i < L2_NEURONS; o_i = o_i + 1)
                        if (neuron_label[o_i] == d_i) best_val = best_val + out_spikes[o_i];
                    score = 1.0 * best_val / neurons_per_class[d_i];
                    if (score > best_score) begin best_score = score; predicted = d_i; end
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
            if (n_tested % 40 == 0)
                $display("  [test] %4d / %0d   correct: %0d   accuracy: %0.1f%%",
                         n_tested, N_TEST, n_correct, 100.0*n_correct/n_tested);
        end

        // ==================================================================
        accuracy_pct = (n_tested > 0) ? 100.0*n_correct/n_tested : 0.0;
        $display("");
        $display("================================================================");
        $display("  TWO-LAYER RESULTS");
        $display("----------------------------------------------------------------");
        $display("  Test images     : %0d", n_tested);
        $display("  Correct         : %0d", n_correct);
        $display("  ACCURACY        : %0.2f %%", accuracy_pct);
        $display("  Random baseline : 10.00 %%");
        $display("");
        $display("  Per-digit accuracy:");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
            if (per_digit_total[d_i] > 0)
                $display("    digit %0d : %3d / %3d  (%0.1f%%)",
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
        $display("  Health: hidden spikes=%0d  output spikes=%0d", total_hidden, total_out);
        $display("          queue overflow=%0b  stdp timeout=%0b  router overflow=%0b",
                 q_ovf, txn_to, rtr_ovf);
        $display("================================================================");
        $finish;
    end

endmodule
