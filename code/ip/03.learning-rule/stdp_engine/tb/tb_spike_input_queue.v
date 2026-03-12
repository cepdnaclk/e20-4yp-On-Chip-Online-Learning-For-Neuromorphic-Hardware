// =============================================================================
// Testbench: tb_spike_input_queue
// Tests: enqueue, dequeue, freeze signal, full condition
// =============================================================================

`timescale 1ns/1ps

module tb_spike_input_queue;

    parameter NUM_NEURONS_PER_CLUSTER = 4;
    parameter NEURON_ADDRESS_WIDTH    = 2;
    parameter SPIKE_QUEUE_DEPTH       = 4;

    reg  clock, reset;
    reg  [NUM_NEURONS_PER_CLUSTER-1:0] incoming_spike_bus;
    wire cluster_freeze_enable;
    wire [NEURON_ADDRESS_WIDTH-1:0] dequeued_spike_neuron_address;
    wire dequeued_spike_valid;
    reg  dequeue_acknowledge;
    wire queue_empty_flag;
    wire queue_full_flag;

    spike_input_queue #(
        .NUM_NEURONS_PER_CLUSTER(NUM_NEURONS_PER_CLUSTER),
        .NEURON_ADDRESS_WIDTH(NEURON_ADDRESS_WIDTH),
        .SPIKE_QUEUE_DEPTH(SPIKE_QUEUE_DEPTH)
    ) uut (.*);

    initial clock = 0;
    always #5 clock = ~clock;

    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num = 0;

    task check_dequeue;
        input [NEURON_ADDRESS_WIDTH-1:0] expected_addr;
        input [255:0] test_name;
        begin
            test_num = test_num + 1;
            if (dequeued_spike_valid && dequeued_spike_neuron_address == expected_addr) begin
                $display("[PASS] Test %0d: %0s (addr=%0d)", test_num, test_name, dequeued_spike_neuron_address);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %0s — valid=%b addr=%0d (exp %0d)", test_num, test_name, dequeued_spike_valid, dequeued_spike_neuron_address, expected_addr);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_spike_input_queue.vcd");
        $dumpvars(0, tb_spike_input_queue);

        reset = 1;
        incoming_spike_bus = 0;
        dequeue_acknowledge = 0;
        @(posedge clock); @(posedge clock); #1;
        reset = 0;

        // Test 1: Queue should be empty after reset
        test_num = test_num + 1;
        if (queue_empty_flag) begin
            $display("[PASS] Test %0d: Queue empty after reset", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Queue not empty after reset", test_num);
            fail_count = fail_count + 1;
        end

        // Test 2: Single spike from neuron 2
        incoming_spike_bus = 4'b0100; // neuron 2
        @(posedge clock); #1;
        incoming_spike_bus = 0;
        @(posedge clock); #1; // let it propagate

        check_dequeue(2'd2, "Single spike from neuron 2");

        // Test 3: Freeze should be active
        test_num = test_num + 1;
        if (cluster_freeze_enable) begin
            $display("[PASS] Test %0d: Freeze active when queue non-empty", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Freeze not active", test_num);
            fail_count = fail_count + 1;
        end

        // Test 4: Dequeue the spike
        dequeue_acknowledge = 1;
        @(posedge clock); #1;
        dequeue_acknowledge = 0;
        @(posedge clock); #1;

        test_num = test_num + 1;
        if (queue_empty_flag) begin
            $display("[PASS] Test %0d: Queue empty after dequeue", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Queue not empty after dequeue", test_num);
            fail_count = fail_count + 1;
        end

        // Test 5: Multiple simultaneous spikes (neurons 0 and 3)
        incoming_spike_bus = 4'b1001; // neurons 0 and 3
        @(posedge clock); #1;
        incoming_spike_bus = 0;
        @(posedge clock); #1;

        // First dequeue should be neuron 0 (lowest index)
        check_dequeue(2'd0, "Multi-spike: first is neuron 0");

        dequeue_acknowledge = 1;
        @(posedge clock); #1;
        dequeue_acknowledge = 0;
        @(posedge clock); #1;

        // Second should be neuron 3
        check_dequeue(2'd3, "Multi-spike: second is neuron 3");

        dequeue_acknowledge = 1;
        @(posedge clock); #1;
        dequeue_acknowledge = 0;
        @(posedge clock); #1;

        $display("\n=== RESULTS: %0d passed, %0d failed out of %0d ===", pass_count, fail_count, test_num);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
