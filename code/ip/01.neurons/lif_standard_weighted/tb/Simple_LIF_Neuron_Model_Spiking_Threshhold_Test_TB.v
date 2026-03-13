// `include "Simple_LIF_Neuron_Model.v"
`timescale 1ps/1ps
module LIF_TB();

//Testbench signals

//Clock signal generation
reg clock_tb = 1'b0;
always #5 clock_tb = ~clock_tb; // 10 time units clock period

//Reset signal
reg reset_tb = 1'b1;
reg input_spike_tb = 1'b0;
reg enable_tb = 1'b0;


wire spike_output_tb;
//Intatiating the neuron model

simple_LIF_Neuron_Model neuron_instance_01(
    .clock(clock_tb),
    .reset(reset_tb),
    .enable(enable_tb),
    .input_spike_wire(input_spike_tb), // example spike input
    .spike_output_wire(spike_output_tb)
);

initial begin
    // Initialize waveform dump
    $dumpfile("LIF_Neuron_waveform.vcd");
    $dumpvars(0, LIF_TB);
    
    // Test sequence

    // Initial reset
    #10;
    reset_tb = 1'b1;
    enable_tb = 1'b1;
    #10;
    reset_tb = 1'b0;
    #20;


    //Generate input spikes
    //1st spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //2nd spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //3rd spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //4th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //5th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //6th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //7th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //8th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //9th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    #8;
    //10th spike
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;
    // 11th spike to cross threshold
    #8;
    input_spike_tb = 1'b1;
    #2;
    input_spike_tb = 1'b0;  
    





    
    // Run for more time to observe behavior
    #1000;
    
    $display("Simulation completed");
    $finish;

end 


endmodule