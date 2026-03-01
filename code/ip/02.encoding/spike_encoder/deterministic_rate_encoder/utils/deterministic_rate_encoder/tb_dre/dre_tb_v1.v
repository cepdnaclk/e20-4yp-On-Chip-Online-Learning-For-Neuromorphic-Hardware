`timescale 1ns/1ps

module dre_tb;

	// DUT input/output signals.
	// DUT exposes 8-bit intensity index and 8-bit interval output.
	// This TB validates the LUT contents analytically for all 256 intensity indices.
	reg [7:0] input_intensity_val;
	wire [7:0] spike_interval_output;

	integer intensity;
	integer expected_interval;
	integer observed_interval;
	integer previous_interval;
	integer total_checks;
	integer error_count;

	deterministic_rate_encoder dut (
		.input_intensity_val(input_intensity_val),
		.spike_interval_output(spike_interval_output)
	);

	// Analytical reference model derived from the existing Python verification script:
	// interval = floor(100 / (1 + 19*(intensity/255)))
	//          = floor(25500 / (255 + 19*intensity))
	function integer expected_interval_from_intensity;
		input integer intensity_val;
		begin
			expected_interval_from_intensity = 25500 / (255 + (19 * intensity_val));
		end
	endfunction

	// Optional waveform dump for debugging and visual inspection.
	initial begin
		$dumpfile("dre_tb_v1.vcd");
		$dumpvars(0, dre_tb);
	end

	initial begin
		total_checks = 0;
		error_count = 0;
		previous_interval = 32'h7fffffff;

		$display("============================================================");
		$display("DRE TB START: Analytical validation of encoded interval LUT");
		$display("Formula: interval = floor(25500 / (255 + 19*intensity))");
		$display("============================================================");

		// 1) Full LUT sweep (0..255) against analytical reference.
		for (intensity = 0; intensity < 256; intensity = intensity + 1) begin
			expected_interval = expected_interval_from_intensity(intensity);
			observed_interval = dut.mem[intensity];
			total_checks = total_checks + 1;

			if (observed_interval !== expected_interval) begin
				error_count = error_count + 1;
				$display("[FAIL][LUT] intensity=%0d expected=%0d observed=%0d", intensity, expected_interval, observed_interval);
			end

			// 2) Monotonicity check: interval should be non-increasing as intensity rises.
			if (observed_interval > previous_interval) begin
				error_count = error_count + 1;
				$display("[FAIL][MONO] intensity=%0d interval increased from %0d to %0d", intensity, previous_interval, observed_interval);
			end
			previous_interval = observed_interval;
		end

		// 3) Boundary checks.
		total_checks = total_checks + 2;
		if (dut.mem[0] !== 100) begin
			error_count = error_count + 1;
			$display("[FAIL][BOUNDARY] intensity=0 expected=100 observed=%0d", dut.mem[0]);
		end
		if (dut.mem[255] !== 5) begin
			error_count = error_count + 1;
			$display("[FAIL][BOUNDARY] intensity=255 expected=5 observed=%0d", dut.mem[255]);
		end

		// 4) Output port behavior check for selected decimal intensities.
		input_intensity_val = 8'd0;
		#1;
		total_checks = total_checks + 1;
		if (spike_interval_output !== dut.mem[0]) begin
			error_count = error_count + 1;
			$display("[FAIL][PORT] input=0 output=%0d mem[0]=%0d", spike_interval_output, dut.mem[0]);
		end

		input_intensity_val = 8'd1;
		#1;
		total_checks = total_checks + 1;
		if (spike_interval_output !== dut.mem[1]) begin
			error_count = error_count + 1;
			$display("[FAIL][PORT] input=1 output=%0d mem[1]=%0d", spike_interval_output, dut.mem[1]);
		end

		$display("============================================================");
		$display("DRE TB SUMMARY: total_checks=%0d errors=%0d", total_checks, error_count);
		if (error_count == 0)
			$display("[PASS] All analytical checks passed.");
		else
			$display("[FAIL] Analytical checks found mismatches.");
		$display("============================================================");

		$finish;
	end

endmodule