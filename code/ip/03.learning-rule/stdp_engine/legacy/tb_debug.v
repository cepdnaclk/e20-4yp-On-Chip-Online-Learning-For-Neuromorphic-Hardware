// Debug testbench to trace STDP controller state
`timescale 1ns/1ps

module simple_LIF_Neuron_Model (
    input  wire        clock,
    input  wire        reset,
    input  wire        enable,
    input  wire        input_spike_wire,
    input  wire [7:0]  weight_input,
    output reg         spike_output_wire
);
    always @(posedge clock) begin
        if (reset) spike_output_wire <= 0;
        else spike_output_wire <= 0;
    end
endmodule

module tb_debug;

    parameter N = 4;

    reg  clock, reset;
    reg  global_cluster_enable;
    reg  decay_enable_pulse;
    reg  [N-1:0] external_spike_input_bus;
    wire [N-1:0] cluster_spike_output_bus;
    wire cluster_busy_flag;

    neuron_cluster #(
        .NUM_NEURONS_PER_CLUSTER    (N),
        .NEURON_ADDRESS_WIDTH       (2),
        .NUM_WEIGHT_BANKS           (N),
        .WEIGHT_BANK_ADDRESS_WIDTH  (2),
        .WEIGHT_BIT_WIDTH           (8),
        .TRACE_VALUE_BIT_WIDTH      (8),
        .DECAY_TIMER_BIT_WIDTH      (12),
        .TRACE_SATURATION_THRESHOLD (256),
        .DECAY_SHIFT_LOG2           (3),
        .TRACE_INCREMENT_VALUE      (32),
        .NUM_TRACE_UPDATE_MODULES   (N),
        .SPIKE_QUEUE_DEPTH          (N),
        .LTP_SHIFT_AMOUNT           (2),
        .LTD_SHIFT_AMOUNT           (2),
        .INCREASE_MODE              (0)
    ) uut (
        .clock(clock), .reset(reset),
        .global_cluster_enable(global_cluster_enable),
        .decay_enable_pulse(decay_enable_pulse),
        .external_spike_input_bus(external_spike_input_bus),
        .cluster_spike_output_bus(cluster_spike_output_bus),
        .cluster_busy_flag(cluster_busy_flag)
    );

    initial clock = 0;
    always #5 clock = ~clock;

    integer cycle_count;

    // Monitor key signals
    always @(posedge clock) begin
        if (!reset && cycle_count < 100) begin
            $display("cyc=%0d state=%0d busy=%b pending=%0d received=%0d row_cap=%b act_a=%b act_b=%b col_step=%0d arb_result_v=%b arb_busy=%b q_empty=%b q_valid=%b",
                cycle_count,
                uut.stdp_ctrl_inst.state_register,
                uut.stdp_ctrl_inst.stdp_controller_busy_flag,
                uut.stdp_ctrl_inst.pending_trace_result_count_register,
                uut.stdp_ctrl_inst.received_trace_result_count_register,
                uut.stdp_ctrl_inst.row_read_data_captured_flag_register,
                uut.stdp_ctrl_inst.activity_a_complete_register,
                uut.stdp_ctrl_inst.activity_b_complete_register,
                uut.stdp_ctrl_inst.column_step_counter_register,
                uut.trace_arbiter_inst.result_valid,
                uut.trace_arbiter_inst.all_modules_busy_flag,
                uut.spike_queue_inst.queue_empty_flag,
                uut.spike_queue_inst.dequeued_spike_valid
            );
            cycle_count = cycle_count + 1;
        end
    end

    initial begin
        cycle_count = 0;
        reset = 1;
        global_cluster_enable = 0;
        decay_enable_pulse = 0;
        external_spike_input_bus = 0;
        repeat(3) @(posedge clock);
        reset = 0;
        @(posedge clock);

        global_cluster_enable = 1;
        @(posedge clock);
        @(posedge clock);

        external_spike_input_bus = 4'b0001;
        @(posedge clock);
        external_spike_input_bus = 0;

        repeat(50) @(posedge clock);
        $display("Final: busy=%b state=%0d", cluster_busy_flag, uut.stdp_ctrl_inst.state_register);
        $finish;
    end

endmodule
