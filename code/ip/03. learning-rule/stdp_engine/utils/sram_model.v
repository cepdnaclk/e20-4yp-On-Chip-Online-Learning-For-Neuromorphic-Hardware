// sram_model.v
// Simple Dual-Port RAM model (Read/Write)
module sram_model #(
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 64  // Wide width (e.g. 4 neurons * 16-bit weights)
)(
    input wire clk,
    input wire write_en,
    input wire [ADDR_WIDTH-1:0] addr,
    input wire [DATA_WIDTH-1:0] data_in,
    output reg [DATA_WIDTH-1:0] data_out
);

    // In FPGA this infers Block RAM (BRAM)
    reg [DATA_WIDTH-1:0] memory [0:(2**ADDR_WIDTH)-1];

    always @(posedge clk) begin
        if (write_en) begin
            memory[addr] <= data_in;
        end
        data_out <= memory[addr];
    end
endmodule
