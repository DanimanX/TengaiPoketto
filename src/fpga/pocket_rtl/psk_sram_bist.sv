// psk_sram_bist: power-up self-test of the work-RAM SRAM through psk_sram.
//
// Runs once after configuration, while the core is still held in reset for
// the ROM load (the CPU cannot touch the SRAM meanwhile; `busy` muxes the
// psk_sram port over to this module). Two modes, each a full march of all
// 64K words with an address-dependent pattern, written then read back, then
// the same with the pattern inverted:
//
//   mode 0 "slow"  : psk_sram slow=1 (WE# low 8 clks), reads sampled 11 clks
//                    late -- generous margins everywhere.
//   mode 1 "normal": exactly the CPU's EXT_WORKRAM protocol and minimum
//                    spacing (write: wel/weh at c1, ack at c6, next ph1 at c9;
//                    read: capture at c8, next access at c10).
//
// slow OK + normal FAIL -> a timing problem; both FAIL -> the SRAM is not
// working at all (look at got/raw0: 0000/FFFF = nothing driving the bus,
// other values = writes not landing or address lines wrong).
// No reset by design: registers power up at configuration, results persist.
`default_nettype none
module psk_sram_bist (
	input  wire        clk,
	input  wire        start,          // level; the test runs once, on the first rise
	output reg         busy = 1'b0,

	output reg  [15:0] b_addr = 16'd0,
	output reg         b_wel = 1'b0,
	output reg         b_weh = 1'b0,
	output reg  [15:0] b_wdata = 16'd0,
	output wire        b_slow,
	input  wire [15:0] b_rdata,        // psk_sram wr_rdata

	output reg  [1:0]  done = 2'b00,   // per mode: [0] slow, [1] normal
	output reg  [15:0] err0 = 16'd0, err1 = 16'd0,          // saturating error counts
	output reg  [15:0] fa0 = 16'd0, fg0 = 16'd0, fe0 = 16'd0,  // slow: first fail addr / got / expected
	output reg  [15:0] fa1 = 16'd0, fg1 = 16'd0, fe1 = 16'd0,  // normal
	output reg  [15:0] raw0 = 16'd0, raw1 = 16'd0             // first read of word 0, per mode
);
	reg        started = 1'b0, start_d = 1'b0;
	reg        mode = 1'b0;            // 0 slow, 1 normal
	reg        inv  = 1'b0;            // pattern inverted
	reg        rd   = 1'b0;            // 0 write pass, 1 read pass
	reg [3:0]  cyc  = 4'd0;
	reg        first_rd = 1'b0;        // next read compare is the first of this mode

	assign b_slow = busy & ~mode;

	function automatic [15:0] pat(input [15:0] a, input i);
		pat = ({a[7:0], a[15:8]} ^ 16'h5AA5 ^ {16{i}});
	endfunction

	// Op lengths and capture points, normal mode = exactly the CPU's margins.
	// b_addr is a register stable from c0, so psk_sram loads sram_a at the end
	// of c0 -- the CPU's settled address only at the end of its c1, so every
	// BIST point sits one clk earlier than the CPU's:
	//   read : sample 6 clk after the address load (CPU: end of c7, taken at
	//          c8 -> here compare at c7); next address 9 clk after the load
	//          (CPU: settled at the end of c11 -> here op length 9).
	//   write: wel reaches psk_sram in c2 (CPU: c1); the next op's address
	//          load lands when the write engine is idle again (CPU: end of
	//          c9 -> here the next op starts at c10).
	// slow: generous on everything (psk_sram slow: WE# 8 clk, idle at c13).
	wire [3:0] w_len = mode ? 4'd10 : 4'd14;
	wire [3:0] r_cap = mode ? 4'd7  : 4'd12;
	wire [3:0] r_len = mode ? 4'd9  : 4'd14;
	wire [3:0] len   = rd ? r_len : w_len;
	wire [15:0] exp  = pat(b_addr, inv);

	always @(posedge clk) begin
		start_d <= start;
		b_wel <= 1'b0;
		b_weh <= 1'b0;

		if (!busy) begin
			if (start && !start_d && !started) begin
				started <= 1'b1;
				busy <= 1'b1;
				mode <= 1'b0; inv <= 1'b0; rd <= 1'b0; cyc <= 4'd0;
				b_addr <= 16'd0;
				first_rd <= 1'b1;
			end
		end else begin
			// write: data on the port from c0, strobe at c1
			if (!rd) begin
				b_wdata <= exp;
				if (cyc == 4'd1) begin b_wel <= 1'b1; b_weh <= 1'b1; end
			end else if (cyc == r_cap) begin
				if (first_rd && b_addr == 16'd0) begin
					if (mode) raw1 <= b_rdata; else raw0 <= b_rdata;
					first_rd <= 1'b0;
				end
				if (b_rdata != exp) begin
					if (!mode) begin
						if (err0 == 16'd0) begin fa0 <= b_addr; fg0 <= b_rdata; fe0 <= exp; end
						if (err0 != 16'hFFFF) err0 <= err0 + 16'd1;
					end else begin
						if (err1 == 16'd0) begin fa1 <= b_addr; fg1 <= b_rdata; fe1 <= exp; end
						if (err1 != 16'hFFFF) err1 <= err1 + 16'd1;
					end
				end
			end

			if (cyc == len - 4'd1) begin
				cyc <= 4'd0;
				b_addr <= b_addr + 16'd1;
				if (b_addr == 16'hFFFF) begin
					// pass finished: write -> read -> (inverted) write -> read
					if (!rd) rd <= 1'b1;
					else begin
						rd <= 1'b0;
						if (!inv) inv <= 1'b1;
						else begin
							inv <= 1'b0;
							done[mode] <= 1'b1;
							if (mode) busy <= 1'b0;
							else begin mode <= 1'b1; first_rd <= 1'b1; end
						end
					end
				end
			end else begin
				cyc <= cyc + 4'd1;
			end
		end
	end
endmodule
`default_nettype wire
