// Filename: sram_model.v
// Description: Simple Dual-Port RAM model (Separate Read and Write ports)

module sram_model #(
    parameter ADDRESS_WIDTH = 10, // Renamed from ADDR_WIDTH
    parameter DATA_WIDTH = 64  
)(
    input wire clock,                  // Renamed from clk
    input wire write_enable,           // Renamed from write_en
    input wire [ADDRESS_WIDTH-1:0] read_address,  // Added separate read address
    input wire [ADDRESS_WIDTH-1:0] write_address, // Added separate write address
    input wire [DATA_WIDTH-1:0] write_data,       // Renamed from data_in
    output reg [DATA_WIDTH-1:0] read_data         // Renamed from data_out
);

    // In FPGA this infers Block RAM (BRAM)
    reg [DATA_WIDTH-1:0] memory_array [0:(2**ADDRESS_WIDTH)-1];

    // Read operation (Synchronous)
    always @(posedge clock) begin
        read_data <= memory_array[read_address];
    end

    // Write operation (Synchronous)
    always @(posedge clock) begin
        if (write_enable) begin
            memory_array[write_address] <= write_data;
        end
    end
endmodule
