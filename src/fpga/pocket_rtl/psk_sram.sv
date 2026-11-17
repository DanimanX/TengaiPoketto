// psk_sram: 68020 work RAM (64K x 16) in the Pocket's async SRAM (10 ns).
//
// maincpu (EXT_WORKRAM=1) holds the word address for a whole bus access,
// pulses wel/weh for one clk at acc_ph==1 and samples read data at
// acc_ph==3. Timeline at clk_sys = 85.9 MHz (11.64 ns):
//   read : address registered to the pins at the end of ph0; data captured
//          by the input register two clks later (~23 ns >> 10 ns tAA + pads)
//   write: WE# low for one clk (11.6 ns >= tWP), data driven for two,
//          UB#/LB# held through the WE# rising edge, OE# released one clk
//          after the data driver lets go of the bus.
`default_nettype none
module psk_sram (
	input  wire        clk,
	input  wire [15:0] wr_addr,
	input  wire        wr_wel,
	input  wire        wr_weh,
	input  wire [15:0] wr_wdata,
	output reg  [15:0] wr_rdata = 16'd0,

	output reg  [16:0] sram_a = 17'd0,
	inout  wire [15:0] sram_dq,
	output reg         sram_oe_n = 1'b1,
	output reg         sram_we_n = 1'b1,
	output reg         sram_ub_n = 1'b1,
	output reg         sram_lb_n = 1'b1
);
	reg  [15:0] sram_dout = 16'd0;
	reg         sram_drive = 1'b0;
	reg  [1:0]  wr_phase = 2'd0;
	assign sram_dq = sram_drive ? sram_dout : 16'hzzzz;

	// Every pin register loads on every clk (no clock enable), so Quartus can
	// pack all of them, the dq output-enable included, into the IOE.
	// wr_wdata (cpu_dout) is held by the CPU until its next clkena, which
	// cannot come before the edge that ends phase 1, so sampling it each
	// clk keeps the written word stable for the whole WE# pulse.
	wire wr_start = (wr_phase == 2'd0) && (wr_wel | wr_weh);
	reg  lane_ub_n = 1'b1, lane_lb_n = 1'b1;
	always @(posedge clk) begin
		sram_a     <= {1'b0, wr_addr};
		wr_rdata   <= sram_dq;
		sram_dout  <= wr_wdata;
		sram_we_n  <= ~wr_start;                                // one clk low
		sram_drive <= wr_start | (wr_phase == 2'd1);            // two clks
		// OE# stays off one clk after the data driver releases (no fight)
		sram_oe_n  <= wr_start | (wr_phase != 2'd0);
		// byte lanes are held through the WE# rising edge (phase 1)
		sram_ub_n  <= wr_start ? ~wr_weh : (wr_phase == 2'd1) ? lane_ub_n : 1'b0;
		sram_lb_n  <= wr_start ? ~wr_wel : (wr_phase == 2'd1) ? lane_lb_n : 1'b0;
		if (wr_start) begin lane_ub_n <= ~wr_weh; lane_lb_n <= ~wr_wel; end
		case (wr_phase)
			2'd0:    wr_phase <= wr_start ? 2'd1 : 2'd0;
			2'd1:    wr_phase <= 2'd2;
			default: wr_phase <= 2'd0;
		endcase
	end

endmodule
`default_nettype wire
