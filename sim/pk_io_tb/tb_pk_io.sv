// tb_pk_io: Verilator testbench for pk_io_psk (DUT is not modified).
//
// Loads a synthetic .rom image over the APF bridge exactly the way the Pocket
// does (32-bit words, bridge_endian_little), models psikyo_top's fast-loader
// port as an SDRAM write responder, and checks that the header fields, the
// SH404 MCU table and every 16-bit SDRAM word arrived intact.
`timescale 1ns/1ps

module tb_pk_io;

	// ------------------------------------------------------------------
	// Image geometry
	// ------------------------------------------------------------------
	localparam int IMG_BYTES = 544 + 4096;   // 0x220 header+blob, then payload
	localparam int IMG_WORDS = IMG_BYTES / 4;
	localparam int PAY_BYTES = 4096;
	localparam int PAY_WORDS = PAY_BYTES / 2;

	// ------------------------------------------------------------------
	// Clocks / power-on
	// ------------------------------------------------------------------
	reg clk_74a = 1'b0;   // 13.468 ns
	reg clk_sys = 1'b0;   // 11.64 ns

	always #6.734 clk_74a = ~clk_74a;
	always #5.82  clk_sys = ~clk_sys;

	reg apf_reset_n  = 1'b1;
	reg pll_locked   = 1'b0;

	initial begin
		pll_locked = 1'b0;
		repeat (8) @(posedge clk_sys);
		pll_locked = 1'b1;
	end

	// ------------------------------------------------------------------
	// DUT signals
	// ------------------------------------------------------------------
	reg  [31:0] bridge_addr       = 32'd0;
	reg         bridge_wr         = 1'b0;
	reg  [31:0] bridge_wr_data    = 32'd0;
	reg  [31:0] cont1_key         = 32'd0;
	reg  [31:0] cont2_key         = 32'd0;
	reg         apf_dataslot_complete = 1'b0;

	wire [31:0] joystick_0, joystick_1;
	wire        core_reset_btn;
	wire [1:0]  audio_vol;
	wire [7:0]  board_flags;
	wire        vertical;
	wire [63:0] dip_sw, dip_eff;
	wire        mcu_table_we;
	wire [7:0]  mcu_table_waddr, mcu_table_wdata;
	wire        ldr_active, ldr_req, ldr_we16;
	wire [24:0] ldr_addr;
	wire [15:0] ldr_data;

	reg         ldr_busy = 1'b0;      // driven by the responder model
	wire        boot_done, fifo_ovf;

	pk_io_psk dut (
		.clk_74a(clk_74a),
		.apf_reset_n(apf_reset_n),
		.bridge_addr(bridge_addr),
		.bridge_wr(bridge_wr),
		.bridge_wr_data(bridge_wr_data),
		.cont1_key(cont1_key),
		.cont2_key(cont2_key),
		.apf_dataslot_complete(apf_dataslot_complete),
		.clk_sys(clk_sys),
		.pll_locked(pll_locked),
		.joystick_0(joystick_0),
		.joystick_1(joystick_1),
		.core_reset_btn(core_reset_btn),
		.audio_vol(audio_vol),
		.board_flags(board_flags),
		.vertical(vertical),
		.dip_sw(dip_sw),
		.dip_eff(dip_eff),
		.mcu_table_we(mcu_table_we),
		.mcu_table_waddr(mcu_table_waddr),
		.mcu_table_wdata(mcu_table_wdata),
		.ldr_active(ldr_active),
		.ldr_req(ldr_req),
		.ldr_addr(ldr_addr),
		.ldr_data(ldr_data),
		.ldr_we16(ldr_we16),
		.ldr_busy(ldr_busy),
		.boot_done(boot_done),
		.fifo_ovf(fifo_ovf)
	);

	// ------------------------------------------------------------------
	// .rom image (built in-memory, little-endian on the wire)
	// ------------------------------------------------------------------
	logic [7:0] img [0:IMG_BYTES-1];

	task automatic build_image;
		int i, j;
		begin
			for (i = 0; i < IMG_BYTES; i++) img[i] = 8'h00;

			img[0] = 8'h50; img[1] = 8'h53; img[2] = 8'h4B; img[3] = 8'h01;  // "PSK\x01"
			img[4] = 8'h1D;                                   // board flags
			img[5] = 8'h01;                                   // version
			img[6] = 8'h30; img[7] = 8'h00;                   // blob_len = 48
			img[8] = 8'h00; img[9] = 8'h10; img[10] = 8'h00; img[11] = 8'h00; // 4096
			img[12] = 8'h00; img[13] = 8'h00; img[14] = 8'h00; img[15] = 8'h00; // CRC
			img[16] = 8'hFD; img[17] = 8'hFF; img[18] = 8'h0F; img[19] = 8'hFF;
			img[20] = 8'hFF; img[21] = 8'hFF; img[22] = 8'hFF; img[23] = 8'hFF;
			img[24] = 8'h01;                                  // vertical
			img[25] = 8'h00; img[26] = 8'h00; img[27] = 8'h00;
			img[28] = 8'h00; img[29] = 8'h00; img[30] = 8'h00; img[31] = 8'h00;

			// board blob, 512 bytes at 0x020
			for (j = 0; j < 512; j++) begin
				if (j == 0)       img[32 + j] = 8'h1D;
				else if (j < 4)   img[32 + j] = 8'h00;
				else if (j < 48)  img[32 + j] = (j * 7 + 3) & 8'hFF;
				else              img[32 + j] = 8'h00;
			end

			// payload, 4096 bytes at 0x220
			for (i = 0; i < PAY_BYTES; i++) img[544 + i] = (i * 37 + 11) & 8'hFF;
		end
	endtask

	// ------------------------------------------------------------------
	// bridge driver: 64-word bursts, 300 clk_74a idle cycles between them
	// ------------------------------------------------------------------
	task automatic send_image;
		int i;
		reg [31:0] a;
		begin
			for (i = 0; i < IMG_WORDS; i++) begin
				if ((i != 0) && ((i % 64) == 0)) begin
					bridge_wr = 1'b0;
					repeat (300) @(negedge clk_74a);
				end
				a = i * 4;
				bridge_addr    = a;
				bridge_wr_data = {img[a+3], img[a+2], img[a+1], img[a]};
				bridge_wr      = 1'b1;
				@(negedge clk_74a);
			end
			bridge_wr = 1'b0;
		end
	endtask

	// ------------------------------------------------------------------
	// psikyo_top fast-loader port: SDRAM write responder (clk_sys)
	// ------------------------------------------------------------------
	localparam int MEMW = 4096;
	reg  [15:0] mem [0:MEMW-1];      // mem[ldr_addr >> 1]

	reg  [3:0] busy_left = 4'd0;
	reg        arm       = 1'b1;     // one accept per ldr_req assertion
	integer    req_count = 0;
	reg        we16_err   = 1'b0;
	reg        active_err = 1'b0;
	reg        underflow_err = 1'b0;

	initial begin
		int m;
		for (m = 0; m < MEMW; m++) mem[m] = 16'h0000;
	end

	always @(posedge clk_sys) begin
		if (!pll_locked) begin
			ldr_busy  <= 1'b0;
			busy_left <= 4'd0;
			arm       <= 1'b1;
		end else if (ldr_busy) begin
			if (!ldr_we16) we16_err <= 1'b1;
			if (busy_left == 4'd1) begin
				ldr_busy  <= 1'b0;      // busy high for 6 clk_sys cycles
				busy_left <= 4'd0;
			end else begin
				busy_left <= busy_left - 4'd1;
			end
		end else begin
			if (ldr_req && arm) begin
				mem[ldr_addr[24:1]] <= ldr_data;
				ldr_busy  <= 1'b1;
				busy_left <= 4'd6;
				arm       <= 1'b0;
				req_count <= req_count + 1;
				if (!ldr_active) active_err <= 1'b1;
				if (!ldr_we16)   we16_err   <= 1'b1;
			end else if (!ldr_req) begin
				arm <= 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------
	// SH404 MCU table writes
	// ------------------------------------------------------------------
	reg [7:0] tbl [0:255];
	integer   mcu_wr_count = 0;
	integer   mcu_hi_count = 0;

	initial begin
		int t;
		for (t = 0; t < 256; t++) tbl[t] = 8'h00;
	end

	always @(posedge clk_sys) begin
		if (mcu_table_we) begin
			tbl[mcu_table_waddr] <= mcu_table_wdata;
			mcu_wr_count <= mcu_wr_count + 1;
			if (mcu_table_waddr >= 8'd44) mcu_hi_count <= mcu_hi_count + 1;
		end
	end

	// ------------------------------------------------------------------
	// Sequence + checks
	// ------------------------------------------------------------------
	integer errors   = 0;
	integer wait_cyc = 0;
	integer k;
	logic [15:0] exp16;
	reg    [7:0] exp8;
	integer bad;

	initial begin : main
		build_image();

		// start the load once the core is out of reset
		wait (pll_locked);
		repeat (10) @(negedge clk_74a);
		send_image();
		apf_dataslot_complete = 1'b1;

		// boot_done, 2 ms timeout (2 ms / 11.64 ns ~= 171822 clk_sys cycles)
		wait_cyc = 0;
		while (!boot_done && wait_cyc < 200_000) begin
			@(posedge clk_sys);
			wait_cyc = wait_cyc + 1;
		end
		if (!boot_done) begin
			$display("FAIL: boot_done never asserted (timeout after %0d clk_sys cycles)", wait_cyc);
			$display("TESTS FAILED");
			$finish;
		end
		$display("INFO: boot_done after %0d clk_sys cycles; ldr requests=%0d; mcu writes=%0d",
		         wait_cyc, req_count, mcu_wr_count);

		// ---- (a) payload lander ------------------------------------
		bad = 0;
		for (k = 0; k < PAY_WORDS; k++) begin
			exp16 = {img[544 + 2*k + 1], img[544 + 2*k]};
			if (mem[k] !== exp16) begin
				if (bad < 8) $display("FAIL: payload word %0d: mem=%04h expected %04h", k, mem[k], exp16);
				bad = bad + 1;
			end
		end
		if (bad == 0) $display("PASS: payload image (all %0d 16-bit words match)", PAY_WORDS);
		else begin
			$display("FAIL: payload image: %0d of %0d 16-bit words mismatch", bad, PAY_WORDS);
			errors = errors + 1;
		end

		if (req_count == PAY_WORDS) $display("PASS: fast-loader write count == %0d", PAY_WORDS);
		else begin
			$display("FAIL: fast-loader write count: observed %0d, expected %0d", req_count, PAY_WORDS);
			errors = errors + 1;
		end

		if (!we16_err) $display("PASS: ldr_we16 high for every fast-loader transfer");
		else begin
			$display("FAIL: ldr_we16 was low during a fast-loader transfer");
			errors = errors + 1;
		end

		if (!active_err) $display("PASS: ldr_active high for every fast-loader transfer");
		else begin
			$display("FAIL: ldr_active was low while the fast loader was writing");
			errors = errors + 1;
		end

		// ---- (b) header fields -------------------------------------
		if (board_flags == 8'h1D) $display("PASS: board_flags == 0x1D");
		else begin
			$display("FAIL: board_flags: observed 0x%02h, expected 0x1D", board_flags);
			errors = errors + 1;
		end

		if (vertical === 1'b1) $display("PASS: vertical == 1");
		else begin
			$display("FAIL: vertical: observed %0b, expected 1", vertical);
			errors = errors + 1;
		end

		if (dip_sw === 64'hFFFF_FFFF_FF0F_FFFD) $display("PASS: dip_sw == 0xFFFFFFFFFF0FFFFD");
		else begin
			$display("FAIL: dip_sw: observed 0x%016h, expected 0xFFFFFFFFFF0FFFFD", dip_sw);
			errors = errors + 1;
		end

		if (dip_eff === dip_sw) $display("PASS: dip_eff == dip_sw (menu at defaults)");
		else begin
			$display("FAIL: dip_eff: observed 0x%016h, expected dip_sw 0x%016h", dip_eff, dip_sw);
			errors = errors + 1;
		end

		// ---- (c) SH404 MCU table -----------------------------------
		bad = 0;
		for (k = 0; k < 44; k++) begin
			exp8 = img[32 + 4 + k];              // blob[4..47]
			if (tbl[k] !== exp8) begin
				if (bad < 8) $display("FAIL: mcu_table[%0d]: got 0x%02h, expected 0x%02h", k, tbl[k], exp8);
				bad = bad + 1;
			end
		end
		if (bad == 0) $display("PASS: SH404 MCU table (44 bytes match blob[4..47])");
		else begin
			$display("FAIL: SH404 MCU table: %0d of 44 bytes mismatch", bad);
			errors = errors + 1;
		end

		if (mcu_hi_count == 0 && mcu_wr_count == 44)
			$display("PASS: no MCU writes above table index 43 (%0d writes total)", mcu_wr_count);
		else begin
			$display("FAIL: MCU writes: %0d total, %0d with index >= 44 (expected 44 and 0)",
			         mcu_wr_count, mcu_hi_count);
			errors = errors + 1;
		end

		// ---- (d) post-load state -----------------------------------
		if (ldr_active === 1'b0) $display("PASS: ldr_active low after boot_done");
		else begin
			$display("FAIL: ldr_active still high after boot_done");
			errors = errors + 1;
		end

		if (fifo_ovf === 1'b0) $display("PASS: fifo_ovf == 0");
		else begin
			$display("FAIL: fifo_ovf asserted (bridge FIFO overflowed)");
			errors = errors + 1;
		end

		if (errors == 0) $display("ALL PASS");
		else             $display("TESTS FAILED");
		$finish;
	end

endmodule
