// tb_psk_sram_bist: psk_sram_bist + psk_sram against the delayed-pin SRAM
// model of sim/sram_tb. DEAD=0: healthy chip, the BIST must report 0 errors
// in both modes and raw = pattern(0). DEAD=1: the chip never drives the bus,
// the BIST must report errors in both modes.
`timescale 1ns/1ps
module tb_psk_sram_bist #(parameter bit DEAD = 1'b0);
	// AS6C2016-55 (the Pocket's SRAM) and the IOE budget used by psk_sram.sv
	localparam real T_OUT  = 10.0;  // FPGA output register -> SRAM pin (worst tco + board)
	localparam real T_IN   = 2.0;   // SRAM -> FPGA input register
	localparam real T_AA   = 55.0;  // address access
	localparam real T_OE   = 30.0;  // OE# low -> data
	localparam real T_HZ   = 30.0;  // OE# high -> high-Z (tOHZ, worst case for contention)
	localparam real SKEW   = 4.5;   // pin-to-pin skew the checks must absorb
	localparam real T_WP   = 45.0, T_DW = 25.0, T_AW = 50.0;

	logic clk = 0;
	always #5.82 clk = ~clk;
	logic start = 0;
	wire [15:0] addr, wdata, rdata;
	wire wel, weh, slow, busy;
	wire [1:0] done;
	wire [15:0] err0, err1, fa0, fg0, fe0, fa1, fg1, fe1, raw0, raw1;
	wire [16:0] sram_a; wire [15:0] sram_dq; wire oe_n, we_n, ub_n, lb_n;
	psk_sram_bist bist (.clk(clk), .start(start), .busy(busy), .b_addr(addr), .b_wel(wel), .b_weh(weh),
		.b_wdata(wdata), .b_slow(slow), .b_rdata(rdata), .done(done), .err0(err0), .err1(err1),
		.fa0(fa0), .fg0(fg0), .fe0(fe0), .fa1(fa1), .fg1(fg1), .fe1(fe1), .raw0(raw0), .raw1(raw1));
	psk_sram dut (.clk(clk), .slow(slow), .wr_addr(addr), .wr_wel(wel), .wr_weh(weh), .wr_wdata(wdata),
		.wr_rdata(rdata), .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(oe_n), .sram_we_n(we_n),
		.sram_ub_n(ub_n), .sram_lb_n(lb_n));
	// ---- pins as the SRAM sees them (transport delay) ----
	logic [16:0] a_p = 0;
	logic        oe_p = 1, we_p = 1, ub_p = 1, lb_p = 1, drv_p = 0;
	logic [15:0] dout_p = 0;
	always @(sram_a)          a_p    <= #(T_OUT) sram_a;
	always @(oe_n)            oe_p   <= #(T_OUT) oe_n;
	always @(we_n)            we_p   <= #(T_OUT) we_n;
	always @(ub_n)            ub_p   <= #(T_OUT) ub_n;
	always @(lb_n)            lb_p   <= #(T_OUT) lb_n;
	always @(dut.sram_drive)  drv_p  <= #(T_OUT) dut.sram_drive;
	always @(dut.sram_dout)   dout_p <= #(T_OUT) dut.sram_dout;

	// ---- async SRAM model: 128K x 16 ----
	logic [15:0] mem [0:131071];
	logic [15:0] aa_q = 16'hxxxx;     // array output after tAA
	logic        oe_ok = 0;           // output enabled after tOE / tHZ
	wire         rd_en = !oe_p && we_p;
	always @(a_p) begin
		aa_q <= 16'hxxxx;                       // invalid while settling
		aa_q <= #(T_AA) mem[a_p];
	end
	always @(rd_en) begin
		if (rd_en) oe_ok <= #(T_OE) 1'b1;
		else       oe_ok <= #(T_HZ) 1'b0;
	end
	wire         sram_drv = oe_ok && rd_en;
	logic [15:0] sram_out;
	always @(aa_q or sram_drv) sram_out <= #(T_IN) ((sram_drv && !DEAD) ? aa_q : 16'hzzzz);
	assign sram_dq = sram_out;   // the DUT drives the same net through its own tri-state

	int errors = 0;
	// write commits on WE# rising edge, per byte lane, data as seen at the SRAM
	always @(posedge we_p) begin
		if (!lb_p) mem[a_p][7:0]  = dout_p[7:0];
		if (!ub_p) mem[a_p][15:8] = dout_p[15:8];
		// the array output follows the new contents (same address, no a_p event)
		aa_q <= #(T_AA) mem[a_p];
		if (!drv_p || ^dout_p === 1'bx) begin
			$display("FAIL: write without driven data at %t", $time); errors++;
		end
	end
	// write timing at the SRAM pins, each with SKEW of margin
	realtime we_fall = 0, d_chg = 0, a_chg = 0;
	always @(negedge we_p) we_fall = $realtime;
	always @(dout_p or drv_p) d_chg = $realtime;
	always @(a_p) a_chg = $realtime;
	always @(posedge we_p) begin
		if ($realtime - we_fall < T_WP + SKEW) begin
			$display("FAIL: tWP %0.1f ns at %t", $realtime - we_fall, $time); errors++; end
		if ($realtime - d_chg < T_DW + SKEW) begin
			$display("FAIL: tDW %0.1f ns at %t", $realtime - d_chg, $time); errors++; end
		if ($realtime - a_chg < T_AW + SKEW) begin
			$display("FAIL: tAW %0.1f ns at %t", $realtime - a_chg, $time); errors++; end
	end
	// address must not move while WE# is low
	always @(a_p) if (!we_p) begin
		$display("FAIL: address changed during WE# low at %t", $time); errors++;
	end
	// both sides driving the bus at once
	always @(posedge clk) if (drv_p && sram_drv) begin
		$display("FAIL: bus contention at %t", $time); errors++;
	end

	initial for (int i = 0; i < 131072; i++) mem[i] = 16'hDEAD;
	initial begin
		repeat (5) @(posedge clk); start <= 1;
		wait (done == 2'b11); repeat (4) @(posedge clk);
		$display("DEAD=%0d slow: err %0d first %04h got %04h exp %04h raw %04h | normal: err %0d first %04h got %04h exp %04h raw %04h",
			DEAD, err0, fa0, fg0, fe0, raw0, err1, fa1, fg1, fe1, raw1);
		if (busy) begin $display("FAIL: still busy"); errors++; end
		if (!DEAD && (err0 != 0 || err1 != 0 || raw0 != 16'h5AA5 || raw1 != 16'h5AA5)) begin
			$display("FAIL: healthy SRAM reported errors"); errors++; end
		if (DEAD && (err0 == 0 || err1 == 0)) begin $display("FAIL: dead SRAM not detected"); errors++; end
		if (errors == 0) $display("ALL PASS"); else $display("TESTS FAILED (%0d)", errors);
		$finish;
	end
endmodule
