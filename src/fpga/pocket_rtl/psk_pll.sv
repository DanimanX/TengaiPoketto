// psk_pll: TengaiPoketto core clocks from the Pocket's 74.25 MHz.
//
// The upstream core derives every clock enable (68020 16 MHz, Z80 4 MHz,
// YM2610 8 MHz, OPL4 33.8688 MHz, pixel 7.159 MHz) by Bresenham from
// clk_sys = 945/11 MHz. That is reachable EXACTLY from 74.25 MHz:
//   f_vco   = 74.25 * 140 / 11 = 945.0 MHz   (M = 140, N = 11)
//   clk_sys = 945 / 11  = 85.909091 MHz     (C0 = 11)
//   clk_pix = 945 / 132 = 7.159091 MHz      (C1 = 132)  = clk_sys / 12
//   clk_pix_90                               (C2 = 132, +90 deg)
// The SDRAM clock pin is clk_sys inverted through a DDIO (180 deg, the
// same 5820 ps the MiSTer build uses), so it needs no PLL output.
`default_nettype none
module psk_pll (
	input  wire refclk,
	input  wire rst,
	output wire clk_sys,
	output wire clk_pix,
	output wire clk_pix_90,
	output wire locked
);
	wire [2:0] outclk;
	assign clk_sys    = outclk[0];
	assign clk_pix    = outclk[1];
	assign clk_pix_90 = outclk[2];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("85.909090 MHz"),
		.output_clock_frequency1("7.159090 MHz"),
		.output_clock_frequency2("7.159090 MHz"),
		.phase_shift2("34920 ps"),  // +90 deg of 139.68 ns
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(70), .m_cnt_lo_div(70),                                     // M = 140
		.n_cnt_hi_div(6),  .n_cnt_lo_div(5),                                      // N = 11
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("false"),
		.m_cnt_odd_div_duty_en("false"), .n_cnt_odd_div_duty_en("true"),
		.c_cnt_hi_div0(6),  .c_cnt_lo_div0(5),  .c_cnt_odd_div_duty_en0("true"),  // C0 = 11
		.c_cnt_hi_div1(66), .c_cnt_lo_div1(66), .c_cnt_odd_div_duty_en1("false"), // C1 = 132
		.c_cnt_hi_div2(66), .c_cnt_lo_div2(66), .c_cnt_odd_div_duty_en2("false"), // C2 = 132
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_output_clk_frequency("945.0 MHz"),
		.mimic_fbclk_type("GCLK"),
		.pll_fbclk_mux_1("glb"),
		.pll_fbclk_mux_2("m_cnt"),
		.pll_m_cnt_in_src("ph_mux_clk"),
		.pll_slf_rst("true")
	) pll_i (
		.refclk(refclk), .rst(rst), .fbclk(1'b0),
		.outclk(outclk), .locked(locked), .zdbclk(), .fboutclk()
	);
endmodule
`default_nettype wire
