module bit_extender_8_to_32 (
    input wire [7:0] input_8_bit,
    output reg [31:0] output_wire
);

always @(input_8_bit) begin
    //extendoing the signed bit of 8 bit input to the upper 24 bits of the output
    output_wire <= {{24{input_8_bit[7]}}, input_8_bit}; // Concatenate 24 bits of the sign bit with the 8-bit input to create a 32-bit output    
end
endmodule


