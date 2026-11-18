// psk_sram: 68020 work RAM (64K x 16) in the Pocket's async SRAM.
//
// THE PART: AS6C2016-55BIN (Analogue openfpga "External Hardware": 128K x 16,
// 3.3 V, 55 ns; CE# is not an FPGA pin). Datasheet -55: tAA <= 55, tRC >= 55,
// tWC >= 55, tWP >= 45, tDW >= 25, tOE <= 30, tOHZ <= 30, tAS/tWR/tDH >= 0.
// History, all measured on hardware with the power-up BIST
// (psk_sram_bist.sv): written first for a 10 ns part; a 1-clk WE# (11.6 ns)
// never wrote, a 3-clk WE# (34.9 ns) wrote on some power-ups and not others,
// a 4-clk WE# always wrote. The Saturn reference core
// (LittleInstinct/references/pocket_saturn_core glue/fb_sram.sv) hit the same
// wall and documents the part; the margins below follow its budget: every
// pin is an IOE register and follows its clk edge within tco <= 10 ns, with
// <= 4.5 ns of pin-to-pin skew (incl. board).
//
// THE CPU SIDE: maincpu's address, wel/weh and wdata come straight from
// TG68KdotC_Kernel, and core_constraints.sdc gives every kernel -> register
// path -setup 2, so they are only guaranteed here at the END of acc_ph 1.
//
// Timeline at clk_sys = 85.9 MHz (T = 11.64 ns), c<n> = the clk with acc_ph n:
//
//   read : sram_a follows wr_addr every clk, so the settled address leaves
//          the IOE at the end of c1. wr_rdata (IOE input register) samples
//          the pins every clk; maincpu takes the sample from the end of c7
//          (captures it at the end of c8): 6 clk = 69.8 ns >= 10 (tco) + 55
//          (tAA) + 0.5 + input path. OE# is low whenever no write is running.
//   write: wr_start (wel|weh) is seen in c1. End of c1: address, data and
//          byte lanes latched (held for the whole write, independent of the
//          CPU), OE# high. End of c2: WE# low (tAS = 1 clk). End of c4: data
//          driver on -- 3 clk after OE# rose, 34.9 - 4.5 = 30.4 >= tOHZ, so
//          no contention. End of c7: WE# high -- tWP = 5 clk - 4.5 = 53.7 >=
//          45, tDW = 3 clk - 4.5 = 30.4 >= 25, tAW = 6 clk >= 50. End of c8:
//          driver off (tDH/tWR = 1 clk). End of c9: OE# low again, sram_a
//          follows wr_addr again.
//          maincpu acks the write at the end of c6, so the CPU's next access
//          has its ph1 at c9 at the earliest: its settled address reaches
//          the pins at the end of c9, with OE# low from the same edge, and
//          a following write's wr_start finds the engine idle.
//   slow (BIST only): WE# low 8 clk, data driven 7 clk -- extra margin on
//          everything, to tell a timing failure from a dead connection.
`default_nettype none
module psk_sram (
	input  wire        clk,
	input  wire        slow,       // BIST only (CPU: 0)
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
	assign sram_dq = sram_drive ? sram_dout : 16'hzzzz;

	// wr_phase k is the clk c(k+1); a pin registered from phase k changes at
	// the end of c(k+1). WE# low while phase is 1..we_end, driver on while it
	// is drv_beg..drv_end, idle again after ph_last.
	reg  [3:0]  wr_phase = 4'd0;
	wire [3:0]  we_end  = slow ? 4'd8  : 4'd5;
	wire [3:0]  drv_beg = 4'd3;
	wire [3:0]  drv_end = slow ? 4'd9  : 4'd6;
	wire [3:0]  ph_last = slow ? 4'd10 : 4'd7;

	// Fabric copies of the write, taken at wr_start: the CPU may move its
	// address and data as soon as maincpu acks the write.
	reg  [15:0] lat_addr = 16'd0, lat_data = 16'd0;
	reg         lat_ub_n = 1'b1, lat_lb_n = 1'b1;

	wire wr_start = (wr_phase == 4'd0) && (wr_wel | wr_weh);
	wire writing  = (wr_phase != 4'd0);

	// Every pin register loads on every clk (no clock enable): Quartus packs
	// them, the dq output-enable included, into the IOE.
	always @(posedge clk) begin
		if (wr_start) begin
			lat_addr <= wr_addr;
			lat_data <= wr_wdata;
			lat_ub_n <= ~wr_weh;
			lat_lb_n <= ~wr_wel;
		end

		wr_rdata   <= sram_dq;
		sram_a     <= {1'b0, writing ? lat_addr : wr_addr};
		sram_dout  <= lat_data;
		sram_oe_n  <= wr_start | writing;
		sram_we_n  <= ~(writing && wr_phase <= we_end);
		sram_drive <= writing && wr_phase >= drv_beg && wr_phase <= drv_end;
		sram_ub_n  <= wr_start ? ~wr_weh : writing ? lat_ub_n : 1'b0;
		sram_lb_n  <= wr_start ? ~wr_wel : writing ? lat_lb_n : 1'b0;

		if (wr_start)                   wr_phase <= 4'd1;
		else if (wr_phase == ph_last)   wr_phase <= 4'd0;
		else if (writing)               wr_phase <= wr_phase + 4'd1;
	end

endmodule
`default_nettype wire
