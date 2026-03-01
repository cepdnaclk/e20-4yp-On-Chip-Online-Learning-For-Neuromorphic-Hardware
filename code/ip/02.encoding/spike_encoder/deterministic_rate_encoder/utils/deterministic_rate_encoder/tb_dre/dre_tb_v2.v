`timescale 1ns/1ps

module dre_tb_v2;

    // Decimal intensity stimulus (0..255)
    reg [7:0] intensity_dec;

    // DUT output port (8-bit encoded interval)
    wire [7:0] spike_interval_output;

    // Golden expected 8-bit lookup table values for every decimal intensity
    reg [7:0] expected_lut [0:255];

    // Observed value captured from DUT LUT entry (promoted to 8-bit for comparison)
    reg [7:0] observed_lut_value;

    integer i;
    integer errors;
    integer printed_fails;
    integer mem_word_bits;

    deterministic_rate_encoder dut (
        .input_intensity_val(intensity_dec),
        .spike_interval_output(spike_interval_output)
    );

    // -------------------------------------------------------------------------
    // Golden vectors provided by design intent (decimal index -> 8-bit output)
    // -------------------------------------------------------------------------
    initial begin
        expected_lut[0] = 8'b01100100;
        expected_lut[1] = 8'b01011101;
        expected_lut[2] = 8'b01010111;
        expected_lut[3] = 8'b01010001;
        expected_lut[4] = 8'b01001101;
        expected_lut[5] = 8'b01001000;
        expected_lut[6] = 8'b01000101;
        expected_lut[7] = 8'b01000001;
        expected_lut[8] = 8'b00111110;
        expected_lut[9] = 8'b00111011;
        expected_lut[10] = 8'b00111001;
        expected_lut[11] = 8'b00110110;
        expected_lut[12] = 8'b00110100;
        expected_lut[13] = 8'b00110010;
        expected_lut[14] = 8'b00110000;
        expected_lut[15] = 8'b00101111;
        expected_lut[16] = 8'b00101101;
        expected_lut[17] = 8'b00101100;
        expected_lut[18] = 8'b00101010;
        expected_lut[19] = 8'b00101001;
        expected_lut[20] = 8'b00101000;
        expected_lut[21] = 8'b00100110;
        expected_lut[22] = 8'b00100101;
        expected_lut[23] = 8'b00100100;
        expected_lut[24] = 8'b00100011;
        expected_lut[25] = 8'b00100010;
        expected_lut[26] = 8'b00100010;
        expected_lut[27] = 8'b00100001;
        expected_lut[28] = 8'b00100000;
        expected_lut[29] = 8'b00011111;
        expected_lut[30] = 8'b00011110;
        expected_lut[31] = 8'b00011110;
        expected_lut[32] = 8'b00011101;
        expected_lut[33] = 8'b00011100;
        expected_lut[34] = 8'b00011100;
        expected_lut[35] = 8'b00011011;
        expected_lut[36] = 8'b00011011;
        expected_lut[37] = 8'b00011010;
        expected_lut[38] = 8'b00011010;
        expected_lut[39] = 8'b00011001;
        expected_lut[40] = 8'b00011001;
        expected_lut[41] = 8'b00011000;
        expected_lut[42] = 8'b00011000;
        expected_lut[43] = 8'b00010111;
        expected_lut[44] = 8'b00010111;
        expected_lut[45] = 8'b00010110;
        expected_lut[46] = 8'b00010110;
        expected_lut[47] = 8'b00010110;
        expected_lut[48] = 8'b00010101;
        expected_lut[49] = 8'b00010101;
        expected_lut[50] = 8'b00010101;
        expected_lut[51] = 8'b00010100;
        expected_lut[52] = 8'b00010100;
        expected_lut[53] = 8'b00010100;
        expected_lut[54] = 8'b00010011;
        expected_lut[55] = 8'b00010011;
        expected_lut[56] = 8'b00010011;
        expected_lut[57] = 8'b00010011;
        expected_lut[58] = 8'b00010010;
        expected_lut[59] = 8'b00010010;
        expected_lut[60] = 8'b00010010;
        expected_lut[61] = 8'b00010010;
        expected_lut[62] = 8'b00010001;
        expected_lut[63] = 8'b00010001;
        expected_lut[64] = 8'b00010001;
        expected_lut[65] = 8'b00010001;
        expected_lut[66] = 8'b00010000;
        expected_lut[67] = 8'b00010000;
        expected_lut[68] = 8'b00010000;
        expected_lut[69] = 8'b00010000;
        expected_lut[70] = 8'b00010000;
        expected_lut[71] = 8'b00001111;
        expected_lut[72] = 8'b00001111;
        expected_lut[73] = 8'b00001111;
        expected_lut[74] = 8'b00001111;
        expected_lut[75] = 8'b00001111;
        expected_lut[76] = 8'b00001111;
        expected_lut[77] = 8'b00001110;
        expected_lut[78] = 8'b00001110;
        expected_lut[79] = 8'b00001110;
        expected_lut[80] = 8'b00001110;
        expected_lut[81] = 8'b00001110;
        expected_lut[82] = 8'b00001110;
        expected_lut[83] = 8'b00001101;
        expected_lut[84] = 8'b00001101;
        expected_lut[85] = 8'b00001101;
        expected_lut[86] = 8'b00001101;
        expected_lut[87] = 8'b00001101;
        expected_lut[88] = 8'b00001101;
        expected_lut[89] = 8'b00001101;
        expected_lut[90] = 8'b00001100;
        expected_lut[91] = 8'b00001100;
        expected_lut[92] = 8'b00001100;
        expected_lut[93] = 8'b00001100;
        expected_lut[94] = 8'b00001100;
        expected_lut[95] = 8'b00001100;
        expected_lut[96] = 8'b00001100;
        expected_lut[97] = 8'b00001100;
        expected_lut[98] = 8'b00001100;
        expected_lut[99] = 8'b00001011;
        expected_lut[100] = 8'b00001011;
        expected_lut[101] = 8'b00001011;
        expected_lut[102] = 8'b00001011;
        expected_lut[103] = 8'b00001011;
        expected_lut[104] = 8'b00001011;
        expected_lut[105] = 8'b00001011;
        expected_lut[106] = 8'b00001011;
        expected_lut[107] = 8'b00001011;
        expected_lut[108] = 8'b00001011;
        expected_lut[109] = 8'b00001010;
        expected_lut[110] = 8'b00001010;
        expected_lut[111] = 8'b00001010;
        expected_lut[112] = 8'b00001010;
        expected_lut[113] = 8'b00001010;
        expected_lut[114] = 8'b00001010;
        expected_lut[115] = 8'b00001010;
        expected_lut[116] = 8'b00001010;
        expected_lut[117] = 8'b00001010;
        expected_lut[118] = 8'b00001010;
        expected_lut[119] = 8'b00001010;
        expected_lut[120] = 8'b00001010;
        expected_lut[121] = 8'b00001001;
        expected_lut[122] = 8'b00001001;
        expected_lut[123] = 8'b00001001;
        expected_lut[124] = 8'b00001001;
        expected_lut[125] = 8'b00001001;
        expected_lut[126] = 8'b00001001;
        expected_lut[127] = 8'b00001001;
        expected_lut[128] = 8'b00001001;
        expected_lut[129] = 8'b00001001;
        expected_lut[130] = 8'b00001001;
        expected_lut[131] = 8'b00001001;
        expected_lut[132] = 8'b00001001;
        expected_lut[133] = 8'b00001001;
        expected_lut[134] = 8'b00001001;
        expected_lut[135] = 8'b00001001;
        expected_lut[136] = 8'b00001000;
        expected_lut[137] = 8'b00001000;
        expected_lut[138] = 8'b00001000;
        expected_lut[139] = 8'b00001000;
        expected_lut[140] = 8'b00001000;
        expected_lut[141] = 8'b00001000;
        expected_lut[142] = 8'b00001000;
        expected_lut[143] = 8'b00001000;
        expected_lut[144] = 8'b00001000;
        expected_lut[145] = 8'b00001000;
        expected_lut[146] = 8'b00001000;
        expected_lut[147] = 8'b00001000;
        expected_lut[148] = 8'b00001000;
        expected_lut[149] = 8'b00001000;
        expected_lut[150] = 8'b00001000;
        expected_lut[151] = 8'b00001000;
        expected_lut[152] = 8'b00001000;
        expected_lut[153] = 8'b00001000;
        expected_lut[154] = 8'b00001000;
        expected_lut[155] = 8'b00000111;
        expected_lut[156] = 8'b00000111;
        expected_lut[157] = 8'b00000111;
        expected_lut[158] = 8'b00000111;
        expected_lut[159] = 8'b00000111;
        expected_lut[160] = 8'b00000111;
        expected_lut[161] = 8'b00000111;
        expected_lut[162] = 8'b00000111;
        expected_lut[163] = 8'b00000111;
        expected_lut[164] = 8'b00000111;
        expected_lut[165] = 8'b00000111;
        expected_lut[166] = 8'b00000111;
        expected_lut[167] = 8'b00000111;
        expected_lut[168] = 8'b00000111;
        expected_lut[169] = 8'b00000111;
        expected_lut[170] = 8'b00000111;
        expected_lut[171] = 8'b00000111;
        expected_lut[172] = 8'b00000111;
        expected_lut[173] = 8'b00000111;
        expected_lut[174] = 8'b00000111;
        expected_lut[175] = 8'b00000111;
        expected_lut[176] = 8'b00000111;
        expected_lut[177] = 8'b00000111;
        expected_lut[178] = 8'b00000111;
        expected_lut[179] = 8'b00000110;
        expected_lut[180] = 8'b00000110;
        expected_lut[181] = 8'b00000110;
        expected_lut[182] = 8'b00000110;
        expected_lut[183] = 8'b00000110;
        expected_lut[184] = 8'b00000110;
        expected_lut[185] = 8'b00000110;
        expected_lut[186] = 8'b00000110;
        expected_lut[187] = 8'b00000110;
        expected_lut[188] = 8'b00000110;
        expected_lut[189] = 8'b00000110;
        expected_lut[190] = 8'b00000110;
        expected_lut[191] = 8'b00000110;
        expected_lut[192] = 8'b00000110;
        expected_lut[193] = 8'b00000110;
        expected_lut[194] = 8'b00000110;
        expected_lut[195] = 8'b00000110;
        expected_lut[196] = 8'b00000110;
        expected_lut[197] = 8'b00000110;
        expected_lut[198] = 8'b00000110;
        expected_lut[199] = 8'b00000110;
        expected_lut[200] = 8'b00000110;
        expected_lut[201] = 8'b00000110;
        expected_lut[202] = 8'b00000110;
        expected_lut[203] = 8'b00000110;
        expected_lut[204] = 8'b00000110;
        expected_lut[205] = 8'b00000110;
        expected_lut[206] = 8'b00000110;
        expected_lut[207] = 8'b00000110;
        expected_lut[208] = 8'b00000110;
        expected_lut[209] = 8'b00000110;
        expected_lut[210] = 8'b00000110;
        expected_lut[211] = 8'b00000101;
        expected_lut[212] = 8'b00000101;
        expected_lut[213] = 8'b00000101;
        expected_lut[214] = 8'b00000101;
        expected_lut[215] = 8'b00000101;
        expected_lut[216] = 8'b00000101;
        expected_lut[217] = 8'b00000101;
        expected_lut[218] = 8'b00000101;
        expected_lut[219] = 8'b00000101;
        expected_lut[220] = 8'b00000101;
        expected_lut[221] = 8'b00000101;
        expected_lut[222] = 8'b00000101;
        expected_lut[223] = 8'b00000101;
        expected_lut[224] = 8'b00000101;
        expected_lut[225] = 8'b00000101;
        expected_lut[226] = 8'b00000101;
        expected_lut[227] = 8'b00000101;
        expected_lut[228] = 8'b00000101;
        expected_lut[229] = 8'b00000101;
        expected_lut[230] = 8'b00000101;
        expected_lut[231] = 8'b00000101;
        expected_lut[232] = 8'b00000101;
        expected_lut[233] = 8'b00000101;
        expected_lut[234] = 8'b00000101;
        expected_lut[235] = 8'b00000101;
        expected_lut[236] = 8'b00000101;
        expected_lut[237] = 8'b00000101;
        expected_lut[238] = 8'b00000101;
        expected_lut[239] = 8'b00000101;
        expected_lut[240] = 8'b00000101;
        expected_lut[241] = 8'b00000101;
        expected_lut[242] = 8'b00000101;
        expected_lut[243] = 8'b00000101;
        expected_lut[244] = 8'b00000101;
        expected_lut[245] = 8'b00000101;
        expected_lut[246] = 8'b00000101;
        expected_lut[247] = 8'b00000101;
        expected_lut[248] = 8'b00000101;
        expected_lut[249] = 8'b00000101;
        expected_lut[250] = 8'b00000101;
        expected_lut[251] = 8'b00000101;
        expected_lut[252] = 8'b00000101;
        expected_lut[253] = 8'b00000101;
        expected_lut[254] = 8'b00000101;
        expected_lut[255] = 8'b00000101;
    end

    // Optional waveform dump for post-run debugging
    initial begin
        $dumpfile("dre_tb_v2.vcd");
        $dumpvars(0, dre_tb_v2);
    end

    // -------------------------------------------------------------------------
    // Test procedure
    // 1) Apply decimal intensity index 0..255
    // 2) Read corresponding LUT entry from DUT implementation
    // 3) Compare against expected 8-bit value
    // -------------------------------------------------------------------------
    initial begin
        errors = 0;
        printed_fails = 0;

        #1;
        mem_word_bits = $bits(dut.mem[0]);

        $display("============================================================");
        $display("DRE TB V2 START: Decimal intensity to expected 8-bit mapping");
        $display("============================================================");

        if (mem_word_bits != 8) begin
            $display("[WARN] DUT LUT word width is %0d bits (expected 8).", mem_word_bits);
            $display("[WARN] V2 will still run and report mismatches against 8-bit golden map.");
        end

        for (i = 0; i < 256; i = i + 1) begin
            intensity_dec = i[7:0];
            #1;

            // Promote observed word to 8-bit before comparison.
            // With correct DUT width this line still works as expected.
            observed_lut_value = dut.mem[i];

            if (observed_lut_value !== expected_lut[i]) begin
                errors = errors + 1;
                if (printed_fails < 25) begin
                    $display("[FAIL] intensity=%0d expected=0x%02h observed=0x%02h", i, expected_lut[i], observed_lut_value);
                    printed_fails = printed_fails + 1;
                end
            end
        end

        // Show how the current DUT top port behaves for decimal input (LSB indexing only)
        intensity_dec = 8'd0;
        #1;
        $display("[INFO] Port check: intensity=0  -> spike_interval_output=0x%02h", spike_interval_output);
        intensity_dec = 8'd1;
        #1;
        $display("[INFO] Port check: intensity=1  -> spike_interval_output=0x%02h", spike_interval_output);
        intensity_dec = 8'd2;
        #1;
        $display("[INFO] Port check: intensity=2  -> spike_interval_output=0x%02h", spike_interval_output);

        if (errors == 0) begin
            $display("[PASS] All 256 decimal-to-8-bit mapping checks passed.");
        end else begin
            $display("[FAIL] Total mismatches = %0d (showing first %0d).", errors, printed_fails);
        end

        $display("============================================================");
        $finish;
    end

endmodule
