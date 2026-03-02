//Counter inside neuron
`timescale 1ps/1ps

// Internal Neuron Counter Module
module encoder_counter (
    input wire clock,
    input wire reset,
    input wire enable,
    output wire [31:0] count
);

// Defining registers
reg [31:0] count_reg = 32'b1; // Initialize to 1 to avoid zero count at the start

// Assigning output
assign count = count_reg;

// Counter logic
always @(posedge clock or posedge reset) begin

    // Reset condition
    if (reset) begin

        // Reset count to one (to avoid zero count)
        count_reg <= 32'b1;

    // Increment condition
    end else if (enable) begin

        // Increment count
        count_reg <= count_reg + 1;
    end
end

endmodule