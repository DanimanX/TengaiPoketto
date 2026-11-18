// tb_psk_sram: psk_sram against a behavioral 10 ns async SRAM, driven with
// maincpu's EXT_WORKRAM bus protocol, random byte/word reads and writes,
// back-to-back with the minimum gap, checked against a reference model.
//
// Timing realism (what the first version of this bench lacked, and why it
// passed a design that failed on the Pocket):
//  - The CPU address is NOT settled in ph0: core_constraints.sdc gives every
//    TG68KdotC_Kernel -> register path -setup 2, so the address/wel/weh/wdata
//    are only guaranteed at the register inputs at the END of ph1. The bench
//    drives garbage during ph0 and the real values from ph1.
//  - FPGA -> SRAM pins carry T_OUT of delay (3.3 V LVCMOS 2 mA, IOE tco +
//    board), SRAM -> FPGA T_IN.
//  - maincpu commits a work-RAM write (acc_ready) at the end of ph6 and
//    captures a work-RAM read from wr_rdata at the end of ph8; the CPU can
//    start the next access one clk after acc_ready (the cpu_clkena cycle).
`timescale 1ns/1ps
module tb_psk_sram;
	// AS6C2016-55 (the Pocket's SRAM) and the IOE budget used by psk_sram.sv
	localparam real T_OUT  = 10.0;  // FPGA output register -> SRAM pin (worst tco + board)
	localparam real T_IN   = 2.0;   // SRAM -> FPGA input register
	localparam real T_AA   = 55.0;  // address access
	localparam real T_OE   = 30.0;  // OE# low -> data
	localparam real T_HZ   = 30.0;  // OE# high -> high-Z (tOHZ, worst case for contention)
	localparam real SKEW   = 4.5;   // pin-to-pin skew the checks must absorb
	localparam real T_WP   = 45.0, T_DW = 25.0, T_AW = 50.0;

	logic clk = 0;
	always #5.82 clk = ~clk;          // 85.9 MHz

	logic [15:0] addr = 0, wdata = 0;
	logic        wel = 0, weh = 0;
	wire  [15:0] rdata;
	wire  [16:0] sram_a;
	wire  [15:0] sram_dq;
	wire         oe_n, we_n, ub_n, lb_n;

	psk_sram dut (
		.clk(clk), .slow(1'b0), .wr_addr(addr), .wr_wel(wel), .wr_weh(weh),
		.wr_wdata(wdata), .wr_rdata(rdata),
		.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(oe_n),
		.sram_we_n(we_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n)
	);

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
	always @(aa_q or sram_drv) sram_out <= #(T_IN) (sram_drv ? aa_q : 16'hzzzz);
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

	logic [15:0] ref_mem [0:65535];
	initial for (int i = 0; i < 65536; i++) begin mem[i] = 16'(i * 7); ref_mem[i] = 16'(i * 7); end
	initial for (int i = 65536; i < 131072; i++) mem[i] = 16'hDEAD;

	// ---- maincpu-like bus master ----
	task automatic access(input bit is_wr, input bit lo, input bit hi,
	                      input logic [15:0] a, input logic [15:0] d, input int gap);
		// ph0: address/data unsettled. wel/weh stay 0: maincpu's wr_now is
		// gated by acc_ph == 1, a single-cycle register, so no ph0 strobe.
		@(posedge clk); addr <= 16'($urandom); wdata <= 16'($urandom);
		@(posedge clk); addr <= a; wdata <= d;                           // ph1: settled
		                wel <= is_wr & lo; weh <= is_wr & hi;
		@(posedge clk); wel <= 0; weh <= 0;                              // ph2
		                addr <= a; wdata <= d;
		@(posedge clk);                                                  // ph3
		if (!is_wr) begin
			repeat (5) @(posedge clk);                                   // ph4..ph8
			#1;                                                          // ph8: wr_rdata = pins at end of ph7
			if (rdata !== ref_mem[a]) begin
				$display("FAIL: read %04h = %04h, expected %04h at %t", a, rdata, ref_mem[a], $time);
				errors++;
			end
			@(posedge clk);                                              // ph9: clkena cycle
		end else begin
			repeat (3) @(posedge clk);                                   // ph4..ph6: ack at end of ph6
			@(posedge clk);                                              // ph7: clkena cycle
			if (lo) ref_mem[a][7:0]  = d[7:0];
			if (hi) ref_mem[a][15:8] = d[15:8];
		end
		// the CPU's address moves at the end of the clkena cycle
		repeat (gap) @(posedge clk);
	endtask

	initial begin
		int n_rd, n_wr;
		n_rd = 0; n_wr = 0;
		repeat (4) @(posedge clk);
		// directed: byte writes must not disturb the other lane
		access(1, 1, 0, 16'h0100, 16'hAA55, 0);
		access(0, 0, 0, 16'h0100, 0, 0);
		access(1, 0, 1, 16'h0100, 16'h1234, 0);
		access(0, 0, 0, 16'h0100, 0, 0);
		access(1, 1, 1, 16'hFFFF, 16'hBEEF, 0);
		access(0, 0, 0, 16'hFFFF, 0, 0);
		// random, minimum gap 0..2 clks between accesses
		for (int i = 0; i < 20000; i++) begin
			bit wr; int lanes; logic [15:0] a;
			wr    = ($urandom_range(0, 2) == 0);
			lanes = $urandom_range(1, 3);
			a     = (i % 3 == 0) ? 16'($urandom_range(0, 31)) : 16'($urandom);
			if (wr) n_wr++; else n_rd++;
			access(wr, lanes[0], lanes[1], a, 16'($urandom), $urandom_range(0, 2));
		end
		repeat (8) @(posedge clk);
		// upper half of the SRAM must be untouched (sram_a[16] is always 0)
		for (int i = 65536; i < 131072; i++) if (mem[i] !== 16'hDEAD) begin
			$display("FAIL: write leaked to %05h", i); errors++; break;
		end
		$display("%0d reads, %0d writes checked", n_rd, n_wr);
		if (errors == 0) $display("ALL PASS"); else $display("TESTS FAILED (%0d errors)", errors);
		$finish;
	end
endmodule
