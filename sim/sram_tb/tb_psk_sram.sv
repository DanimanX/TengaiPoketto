// tb_psk_sram: psk_sram against a behavioral 10 ns async SRAM, driven with
// maincpu's EXT_WORKRAM bus protocol (address from ph0, wel/weh pulse at
// ph1, read sampled at the end of ph3), random byte/word reads and writes,
// back-to-back with the minimum gap, checked against a reference model.
`timescale 1ns/1ps
module tb_psk_sram;
	logic clk = 0;
	always #5.82 clk = ~clk;          // 85.9 MHz

	logic [15:0] addr = 0, wdata = 0;
	logic        wel = 0, weh = 0;
	wire  [15:0] rdata;
	wire  [16:0] sram_a;
	wire  [15:0] sram_dq;
	wire         oe_n, we_n, ub_n, lb_n;

	psk_sram dut (
		.clk(clk), .wr_addr(addr), .wr_wel(wel), .wr_weh(weh),
		.wr_wdata(wdata), .wr_rdata(rdata),
		.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(oe_n),
		.sram_we_n(we_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n)
	);

	// ---- async SRAM model: 128K x 16, tAA = tOE = 10 ns ----
	logic [15:0] mem [0:131071];
	logic [15:0] rd_q;
	logic        rd_en;
	always @* rd_en = !oe_n && we_n;
	always @(sram_a or rd_en) begin
		if (rd_en) rd_q <= #10 mem[sram_a];
	end
	logic rd_en_d;
	always @(rd_en) rd_en_d <= #3 rd_en;   // tOLZ / tOHZ ~3 ns
	assign sram_dq = rd_en_d ? rd_q : 16'hzzzz;

	int errors = 0;
	// write commits on WE# rising edge, per byte lane
	always @(posedge we_n) begin
		if (!lb_n) mem[sram_a][7:0]  = sram_dq[7:0];
		if (!ub_n) mem[sram_a][15:8] = sram_dq[15:8];
		if (^sram_dq === 1'bx) begin
			$display("FAIL: write with undriven/contended data at %t", $time); errors++;
		end
	end
	// both sides driving the bus at once
	always @(posedge clk) if (dut.sram_drive && rd_en_d) begin
		$display("FAIL: bus contention at %t", $time); errors++;
	end

	logic [15:0] ref_mem [0:65535];
	initial for (int i = 0; i < 65536; i++) begin mem[i] = 16'(i * 7); ref_mem[i] = 16'(i * 7); end
	initial for (int i = 65536; i < 131072; i++) mem[i] = 16'hDEAD;

	// ---- maincpu-like bus master ----
	task automatic access(input bit is_wr, input bit lo, input bit hi,
	                      input logic [15:0] a, input logic [15:0] d, input int gap);
		@(posedge clk); addr <= a; wdata <= d;                // ph0
		@(posedge clk); if (is_wr) begin wel <= lo; weh <= hi; end   // ph1
		@(posedge clk); wel <= 0; weh <= 0;                   // ph2
		if (!is_wr) begin
			@(posedge clk);                                   // ph3
			@(posedge clk);                                   // capture edge
			if (rdata !== ref_mem[a]) begin
				$display("FAIL: read %04h = %04h, expected %04h at %t", a, rdata, ref_mem[a], $time);
				errors++;
			end
		end else begin
			if (lo) ref_mem[a][7:0]  = d[7:0];
			if (hi) ref_mem[a][15:8] = d[15:8];
		end
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
		// upper half of the SRAM must be untouched (sram_a[16] is always 0)
		for (int i = 65536; i < 131072; i++) if (mem[i] !== 16'hDEAD) begin
			$display("FAIL: write leaked to %05h", i); errors++; break;
		end
		$display("%0d reads, %0d writes checked", n_rd, n_wr);
		if (errors == 0) $display("ALL PASS"); else $display("TESTS FAILED (%0d errors)", errors);
		$finish;
	end
endmodule
