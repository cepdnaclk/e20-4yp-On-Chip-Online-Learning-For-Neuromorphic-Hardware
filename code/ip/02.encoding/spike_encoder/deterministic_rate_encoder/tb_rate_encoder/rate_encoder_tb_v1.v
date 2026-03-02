`timescale 1ns/1ps

module rate_encoder_tb_v1;

    reg clock;
    reg reset;
    reg enable;
    reg [7:0] input_from_data_bus;
    wire spike_encoded_output;

    // DUT
    rate_encoder dut (
        .clock(clock),
        .reset(reset),
        .enable(enable),
        .input_from_data_bus(input_from_data_bus),
        .spike_encoded_output(spike_encoded_output)
    );

    // 100 MHz clock (10 ns period)
    initial begin
        clock = 1'b1;
        forever #1 clock = ~clock;
    end

    // Optional waveform dump
    initial begin
        $dumpfile("rate_encoder_tb_v1.vcd");
        $dumpvars(0, rate_encoder_tb_v1);
    end

    // Simple stimulus: one intensity value, observe output
    initial begin
        reset = 1'b1;
        enable = 1'b0;
        input_from_data_bus = 8'd1; // one test intensity value

        #20; // Hold reset for 20 ns
        reset = 1'b0;
        enable = 1'b1;

        // Observe for a short duration
        repeat (400) begin
            @(posedge clock);
            $display("t=%0t ns | intensity=%0d | spike_out=%0b", $time, input_from_data_bus, spike_encoded_output);
        end

        $finish;
    end

endmodule
