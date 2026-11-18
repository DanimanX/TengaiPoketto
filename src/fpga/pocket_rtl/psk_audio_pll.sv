// f3_audio_pll: Jitter-free 12.288 MHz audio MCLK synthesis for Analogue Pocket
// Reference input: Pocket clk_74a (74.25 MHz)
// Output: 12.288 MHz (48 kHz * 256) using Cyclone V fractional-N PLL
//
// VCO:
//   f_vco = 74.25 * (10 + 9926688 / 2^24) / 1 = 786.432 MHz
//   C0 = 64 -> 12.288 MHz (1.5 ppm error, 0 cycle-to-cycle fractional accumulator jitter)

`default_nettype none

module psk_audio_pll (
	input  wire refclk,     // clk_74a: 74.25 MHz
	input  wire rst,
	output wire audio_mclk, // 12.288 MHz
	output wire locked
);
	wire [0:0] outclk;
	assign audio_mclk = outclk[0];

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("12.288 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(5), .m_cnt_lo_div(5),       // M = 10
		.n_cnt_hi_div(1), .n_cnt_lo_div(1),       // N = 1 (bypassed)
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("true"),
		.m_cnt_odd_div_duty_en("false"), .n_cnt_odd_div_duty_en("false"),
		.c_cnt_hi_div0(32), .c_cnt_lo_div0(32), .c_cnt_odd_div_duty_en0("false"), // C0 = 64
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_fractional_division(9926688),
		.pll_fractional_cout(24),
		.pll_dsm_out_sel("3rd_order"),
		.pll_output_clk_frequency("786.432 MHz"),
		.mimic_fbclk_type("GCLK"),
		.pll_fbclk_mux_1("glb"),
		.pll_fbclk_mux_2("m_cnt"),
		.pll_m_cnt_in_src("ph_mux_clk"),
		.pll_slf_rst("true")
	) pll_i (
		.refclk(refclk),
		.rst(rst),
		.fbclk(1'b0),
		.outclk(outclk),
		.locked(locked),
		.zdbclk(),
		.fboutclk()
	);

endmodule
`default_nettype wire
