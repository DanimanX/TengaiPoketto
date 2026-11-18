`timescale 1ns/1ps
// psk_romcheck: loader write stream -> write-side sum; then the same words read
// back from a memory model through the narrow-bridge port -> read-side sum.
// Two passes: clean (ok must be 1) and one corrupted stored word (ok must be 0).
module tb_psk_romcheck;
	localparam int NW = 1024;

	logic        clk = 1'b0;
	logic        reset = 1'b0;
	logic        ldr_active = 1'b0, ldr_req = 1'b0, ldr_busy = 1'b0;
	logic [24:0] ldr_addr = 25'd0;
	logic [15:0] ldr_data = 16'd0;
	logic        rd_req, rd_valid = 1'b0;
	logic [18:0] rd_addr;
	logic [15:0] rd_data = 16'd0;
	logic        busy, done, ok;
	logic [31:0] wsum, rsum;
	logic [19:0] words;

	always #5 clk = ~clk;

	psk_romcheck dut (
		.clk(clk), .reset(reset),
		.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_busy(ldr_busy),
		.ldr_addr(ldr_addr), .ldr_data(ldr_data),
		.rd_req(rd_req), .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
		.busy(busy), .done(done), .ok(ok), .wsum(wsum), .rsum(rsum), .words(words)
	);

	// ---- memory model: one transaction in flight, answers 5 clk after rd_req ----
	localparam int MEMW = 2048;
	logic [15:0] mem [0:MEMW-1];

	int unsigned cyc = 0;
	int unsigned t_issue = 0;
	bit          in_flight = 1'b0;
	logic [18:0] pend_addr = 19'd0;

	initial for (int i = 0; i < MEMW; i++) mem[i] = 16'h0000;

	always @(posedge clk) begin
		cyc <= cyc + 1;
		if (rd_req) begin
			if (in_flight) begin
				$display("FAIL: rd_req while a read is in flight (addr %0d)", rd_addr);
				$fatal(1);
			end
			in_flight <= 1'b1;
			pend_addr <= rd_addr;
			t_issue   <= cyc;
		end
		if (in_flight && (cyc - t_issue == 5)) begin
			rd_data   <= mem[pend_addr];
			rd_valid  <= 1'b1;
			in_flight <= 1'b0;
		end else begin
			rd_valid <= 1'b0;
		end
	end

	// ---- stimulus ----
	int errors = 0;

	task automatic check(input bit cond, input string msg);
		if (!cond) begin
			$display("FAIL: %s (time %0t)", msg, $time);
			errors++;
		end else $display("ok: %s", msg);
	endtask

	// One loader write: req high, busy rises 2 clk later, falls 3 clk later.
	task automatic loader_word(input [24:0] addr, input [15:0] data);
		@(negedge clk);
		ldr_addr = addr;
		ldr_data = data;
		ldr_req  = 1'b1;
		repeat (2) @(negedge clk);
		ldr_busy = 1'b1;
		repeat (3) @(negedge clk);
		ldr_busy = 1'b0;
		ldr_req  = 1'b0;
		@(negedge clk);
	endtask

	task automatic run_load(input bit corrupt);
		begin
			// fresh load: rising edge of ldr_active clears the state
			@(negedge clk) ldr_active = 1'b1;
			repeat (2) @(negedge clk);

			for (int i = 0; i < NW; i++) begin
				logic [15:0] d;
				d = 16'((i * 16'h9E37) ^ 16'h5A5A) + 16'(i);
				mem[i] = d;
				if (corrupt && i == 777) mem[i] = d ^ 16'h0100;   // stored != written
				loader_word(25'(2 * i), d);
			end

			@(negedge clk) ldr_active = 1'b0;

			wait (done == 1'b1);
			repeat (2) @(negedge clk);
		end
	endtask

	initial begin
		// pass 1: clean
		run_load(1'b0);
		check(done === 1'b1, "clean: done=1");
		check(words == NW, $sformatf("clean: words=%0d (expect %0d)", words, NW));
		check(rsum == wsum, $sformatf("clean: rsum==wsum (%08h vs %08h)", rsum, wsum));
		check(ok === 1'b1, "clean: ok=1");
		check(busy === 1'b0, "clean: busy=0 after done");
		$display("clean:   wsum=%08h rsum=%08h words=%0d", wsum, rsum, words);

		// pass 2: one stored word corrupted
		run_load(1'b1);
		check(done === 1'b1, "corrupt: done=1");
		check(words == NW, "corrupt: words still counted");
		check(rsum != wsum, "corrupt: rsum != wsum");
		check(ok === 1'b0, "corrupt: ok=0");
		$display("corrupt: wsum=%08h rsum=%08h words=%0d", wsum, rsum, words);

		if (errors == 0) begin
			$display("ALL PASS");
			$finish;
		end else begin
			$display("FAIL: %0d error(s)", errors);
			$fatal(1);
		end
	end

	initial begin
		#10_000_000;
		$display("FAIL: timeout");
		$fatal(1);
	end
endmodule
