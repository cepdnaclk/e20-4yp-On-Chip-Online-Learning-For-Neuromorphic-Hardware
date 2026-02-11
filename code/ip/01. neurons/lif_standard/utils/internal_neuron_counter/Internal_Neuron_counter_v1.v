//Counter inside neuron
`timescale 1ps/1ps

// Internal Neuron Counter Module
module Internal_neuron_counter (
    input wire clock,
    input wire reset,
    input wire enable,
    output wire [31:0] count
);

// Defining registers
reg [31:0] count_reg = 32'b0;

// Assigning output
assign count = count_reg;

// Counter logic
always @(posedge clock or posedge reset) begin

    // Reset condition
    if (reset) begin

        // Reset count to zero
        count_reg <= 32'b0;

    // Increment condition
    end else if (enable) begin

        // Increment count
        count_reg <= count_reg + 1;
    end
end

endmodule