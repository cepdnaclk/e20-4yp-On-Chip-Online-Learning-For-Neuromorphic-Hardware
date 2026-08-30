// =============================================================================
// Testbench: tb_mnist_wide   (architecture A)
// Wide multi-cluster MNIST: one plastic layer, many more output neurons.
//
//   NUM_CLUSTERS clusters x 128 neurons, uniform local address map:
//       local   0..99   axons  = the 100 image pixels (SAME input to all)
//       local 100..127  neurons = 28 excitatory, WTA within the cluster
//
//   -> NUM_CLUSTERS * 28 excitatory neurons (112 at 4 clusters) against the
//      28 of the single-cluster run. No hidden layer; the point is capacity.
//
//   The single-cluster result was capped by CLASS COVERAGE: with 28 neurons,
//   digits 2, 6 and 9 were assigned no neuron at all and scored 0 %. Four
//   independent 28-way WTA populations give four times the capacity, so more
//   digits should get represented.
//
//   The router is unused here: every cluster is fed the same pixel spikes
//   directly. Label assignment and voting run across ALL clusters' neurons.
// =============================================================================

`timescale 1ns/1ps

module tb_mnist_wide;

    `include "mnist_config_wide.vh"

    parameter N_TRAIN  = (N_IMAGES * 60) / 100;
    parameter N_ASSIGN = (N_IMAGES * 20) / 100;
    parameter N_TEST   = N_IMAGES - N_TRAIN - N_ASSIGN;

    parameter CLK_PERIOD           = 10;
    parameter DRAIN_LIMIT          = 40000;
    parameter DECAY_TICKS_PER_STEP = 8;
    parameter NUM_CLASSES          = 10;

    // identical to the single-cluster run that scored 29.58 %
    parameter LTP_SHIFT_AMOUNT    = 3;
    parameter LTD_SHIFT_AMOUNT    = 5;
    parameter MEMBRANE_LEAK_SHIFT = 4;
    parameter REFRACTORY_CYCLES   = 8;
    parameter THETA_INCREMENT     = 1200;
    parameter THETA_DECAY_SHIFT   = 7;
    parameter WTA_INHIBIT_CYCLES  = 8;

    parameter W_INIT_MIN = 40;
    parameter W_INIT_MAX = 90;

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
    // Per-cluster configuration (genvar: Icarus needs a constant scope index)
    // =========================================================================
    reg cfg_go = 1'b0;

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CLUSTERS; gc = gc + 1) begin : cfgblk
            integer a, n, rs;
            initial begin
                wait (cfg_go === 1'b1);
                rs = 32'h5EED_0000 + gc;   // per-cluster deterministic seed
                for (a = 0; a < NUM_INPUT; a = a + 1) begin
                    for (n = 0; n < NUM_EXC; n = n + 1) begin
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
            end
        end
    endgenerate

    // =========================================================================
    // Data
    // =========================================================================
    reg [TOTAL_NEURONS-1:0] spike_patterns [0:N_IMAGES*TIMESTEPS_PER_IMG-1];
    reg [3:0]               image_labels   [0:N_IMAGES-1];

    // =========================================================================
    // Live spike counters over ALL clusters' excitatory neurons
    //   flat index e = cluster*NUM_EXC + k
    // =========================================================================
    integer exc_spikes [0:255];
    integer total_exc;
    integer sc_i;
    reg     count_en;

    always @(posedge clock)
        if (count_en)
            for (sc_i = 0; sc_i < TOTAL_EXC; sc_i = sc_i + 1)
                if (spikes[(sc_i / NUM_EXC)*NUM_NEURONS_PER_CLUSTER +
                            NEURON_BASE + (sc_i % NUM_EXC)]) begin
                    exc_spikes[sc_i] = exc_spikes[sc_i] + 1;
                    total_exc        = total_exc + 1;
                end

    // =========================================================================
    // Statistics
    // =========================================================================
    integer class_response   [0:255*10];
    integer class_image_count[0:NUM_CLASSES-1];
    integer neuron_label     [0:255];
    integer neurons_per_class[0:NUM_CLASSES-1];
    integer confusion        [0:NUM_CLASSES*NUM_CLASSES-1];
    integer per_digit_correct[0:NUM_CLASSES-1];
    integer per_digit_total  [0:NUM_CLASSES-1];

    integer img_i, t_i, o_i, d_i, k_i, guard;
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
            for (o_i = 0; o_i < TOTAL_EXC; o_i = o_i + 1) exc_spikes[o_i] = 0;
            clear_membranes();
            for (t_i = 0; t_i < TIMESTEPS_PER_IMG; t_i = t_i + 1) begin
                ext_in = spike_patterns[idx*TIMESTEPS_PER_IMG + t_i];
                @(posedge clock); #1;
                ext_in = {TOTAL_NEURONS{1'b0}};
                drain();
                // #1 after each edge: see DIAGNOSIS.md defect 17
                for (k_i = 0; k_i < DECAY_TICKS_PER_STEP; k_i = k_i + 1) begin
                    decay_pulse = 1; @(posedge clock); #1;
                    decay_pulse = 0; @(posedge clock); #1;
                end
                drain();
            end
        end
    endtask

    // Receptive field probe. Icarus cannot index a generate scope with a
    // runtime variable, so neuron 0 of every cluster is flattened into a wire
    // array by a genvar loop. This works for any NUM_CLUSTERS.
    wire [7:0] rf_probe [0:NUM_CLUSTERS*NUM_INPUT-1];
    genvar gcl, gpx;
    generate
        for (gcl = 0; gcl < NUM_CLUSTERS; gcl = gcl + 1) begin : rfc
            for (gpx = 0; gpx < NUM_INPUT; gpx = gpx + 1) begin : rfp
                assign rf_probe[gcl*NUM_INPUT + gpx] =
                    uut.gen_clusters[gcl].cluster_inst.weight_memory_inst
                        .bank_memory[(NEURON_BASE + gpx) % NUM_NEURONS_PER_CLUSTER][NEURON_BASE];
            end
        end
    endgenerate

    integer rf_r, rf_c, rf_p, rf_w, rf_sum;
    task dump_rf;
        input integer cluster;
        begin
            rf_sum = 0;
            for (rf_p = 0; rf_p < NUM_INPUT; rf_p = rf_p + 1)
                rf_sum = rf_sum + rf_probe[cluster*NUM_INPUT + rf_p];
            $display("    cluster %0d neuron 0 (label %0d, mean weight %0d)",
                     cluster, neuron_label[cluster*NUM_EXC], rf_sum/NUM_INPUT);
            for (rf_r = 0; rf_r < GRID; rf_r = rf_r + 1) begin
                $write("      ");
                for (rf_c = 0; rf_c < GRID; rf_c = rf_c + 1) begin
                    rf_w = rf_probe[cluster*NUM_INPUT + rf_r*GRID + rf_c];
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
        $display("  WIDE MULTI-CLUSTER SNN  -  MNIST");
        $display("----------------------------------------------------------------");
        $display("  clusters        : %0d x %0d neurons = %0d slots",
                 NUM_CLUSTERS, NUM_NEURONS_PER_CLUSTER, TOTAL_NEURONS);
        $display("  per cluster     : %0d axons (same input) + %0d excitatory, WTA",
                 NUM_INPUT, NUM_EXC);
        $display("  excitatory total: %0d   (single-cluster run had 28)", TOTAL_EXC);
        $display("  hidden layer    : none - one plastic layer");
        $display("  plastic synapses: %0d", NUM_CLUSTERS*NUM_INPUT*NUM_EXC);
        $display("  images          : %0d train / %0d assign / %0d test",
                 N_TRAIN, N_ASSIGN, N_TEST);
        $display("================================================================");

        $readmemh("mnist_spikes.hex", spike_patterns);
        $readmemh("mnist_labels.hex", image_labels);

        reset = 1; gce = 0; learn_en = 0; adapt_en = 0;
        mclear = 0; decay_pulse = 0; router_en = 0; count_en = 0;
        ext_in = {TOTAL_NEURONS{1'b0}};
        total_exc = 0;
        repeat (6) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        cfg_go = 1'b1;
        #1;
        @(posedge clock); #1;

        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1) begin
            class_image_count[d_i] = 0;
            neurons_per_class[d_i] = 0;
            per_digit_correct[d_i] = 0;
            per_digit_total[d_i]   = 0;
        end
        for (k_i = 0; k_i < TOTAL_EXC*NUM_CLASSES; k_i = k_i + 1) class_response[k_i] = 0;
        for (k_i = 0; k_i < NUM_CLASSES*NUM_CLASSES; k_i = k_i + 1) confusion[k_i] = 0;

        gce = 1; count_en = 1;   // router deliberately left disabled
        repeat (2) @(posedge clock); #1;

        // ==================================================================
        $display("");
        $display("--- Phase 1: unsupervised STDP training (%0d images) ---", N_TRAIN);
        learn_en = 1; adapt_en = 1;
        for (img_i = 0; img_i < N_TRAIN; img_i = img_i + 1) begin
            run_image(img_i);
            if ((img_i+1) % 100 == 0)
                $display("  [train] %4d / %0d   excitatory spikes: %0d",
                         img_i+1, N_TRAIN, total_exc);
        end
        $display("  training done. excitatory spikes: %0d", total_exc);

        // ==================================================================
        $display("");
        $display("--- Phase 2: label assignment (%0d images) ---", N_ASSIGN);
        learn_en = 0; adapt_en = 1;
        for (img_i = N_TRAIN; img_i < N_TRAIN + N_ASSIGN; img_i = img_i + 1) begin
            run_image(img_i);
            true_label = image_labels[img_i];
            class_image_count[true_label] = class_image_count[true_label] + 1;
            for (o_i = 0; o_i < TOTAL_EXC; o_i = o_i + 1)
                class_response[o_i*NUM_CLASSES + true_label] =
                    class_response[o_i*NUM_CLASSES + true_label] + exc_spikes[o_i];
        end

        active_neurons = 0;
        for (o_i = 0; o_i < TOTAL_EXC; o_i = o_i + 1) begin
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
        $display("  neurons that responded: %0d / %0d", active_neurons, TOTAL_EXC);
        $write("  neurons per digit :");
        for (d_i = 0; d_i < NUM_CLASSES; d_i = d_i + 1)
            $write("  %0d:%0d", d_i, neurons_per_class[d_i]);
        $write("\n");

        $display("");
        $display("--- Learned receptive fields (one per cluster) ---");
        for (k_i = 0; k_i < NUM_CLUSTERS; k_i = k_i + 1) dump_rf(k_i);

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
                    for (o_i = 0; o_i < TOTAL_EXC; o_i = o_i + 1)
                        if (neuron_label[o_i] == d_i) best_val = best_val + exc_spikes[o_i];
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
        $display("  WIDE MULTI-CLUSTER RESULTS");
        $display("----------------------------------------------------------------");
        $display("  Excitatory neurons : %0d  (%0d clusters x %0d)",
                 TOTAL_EXC, NUM_CLUSTERS, NUM_EXC);
        $display("  Test images        : %0d", n_tested);
        $display("  Correct            : %0d", n_correct);
        $display("  ACCURACY           : %0.2f %%", accuracy_pct);
        $display("  Random baseline    : 10.00 %%");
        $display("  Single-cluster ref : 29.58 %% (28 neurons, 1200 images)");
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
        $display("  Health: excitatory spikes=%0d  queue overflow=%0b  stdp timeout=%0b",
                 total_exc, q_ovf, txn_to);
        $display("================================================================");
        $finish;
    end

endmodule
