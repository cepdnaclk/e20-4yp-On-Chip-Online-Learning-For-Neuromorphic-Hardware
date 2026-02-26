module spiker_tb ();
    
reg clock;
reg [31:0] spike_window_time_input;
wire spike_output;
// Global synapse time counter instance

    // Spiker module instance
spiker_module spiker_module_instance_01 (
    .clock(clock),
    .spike_window_time_input(spike_window_time_input),
    .spiker_enable_input(1'b1), // Enable the spiker to generate the spike output
    .spike_output(spike_output)
);

always #1 clock = ~clock;


initial begin

    // Dumps for waveform analysis
    $dumpfile("spiker_tb_v2.vcd");
    $dumpvars(0, spiker_tb);

    // Initialize the clock signal
    clock = 0;
    // Clock toggles in separate always block

    // Test case 1: Set spike window time to 10 and observe the spike output
    #10; // Wait for some time before applying the test case
    spike_window_time_input = 32'h0000000A; // Set spike window time to 10
    #100; // Wait for some time to observe the spike output

    // Test case 2: Set spike window time to 2 and observe the spike output
    spike_window_time_input = 32'h00000002; // Set spike window time to 2
    #100; // Wait for some time to observe the spike output

    // Test case 3: Set spike window time to 0 and observe the spike output
    spike_window_time_input = 32'h00000000; // Set spike window time to 0
    #100; // Wait for some time to observe the spike output

    // Finish the simulation
    $display("Simulation completed.");
    $finish;



end



endmodule