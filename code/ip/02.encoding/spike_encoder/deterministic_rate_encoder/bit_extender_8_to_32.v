module bit_extender_8_to_32 (
    input wire [7:0] input_8_bit,
    output wire [31:0] output_wire
);

always @(input_8_bit) begin
    output_wire <= {24'b0, input_8_bit}; // Concatenate 24 zeros with the 8-bit input to create a 32-bit output      
end
endmodule


