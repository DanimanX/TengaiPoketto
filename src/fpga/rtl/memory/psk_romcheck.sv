// Readback checksum of the 68020 program-ROM region in SDRAM, taken AFTER a
// ROM load, compared against a checksum accumulated from the loader's own
// write stream. Diagnoses "the loader wrote it" vs "the chip holds it":
// a mismatch means the bytes never reached SDRAM (or came back changed).
//
// Deliberately driven by ldr_active EDGES only, with NO reset on any
// register: a load is a clean, unambiguous event, and a zeroed register here
// can only mean "nothing seen yet", never "held in reset" (the same reasoning
// as psikyo_top.sv's ISSP load counters).
//
// Write side: one add per accepted loader word (ldr_req && ldr_busy rising
// edge), only inside the 2MB MAINCPU region. Read side: after ldr_active
// falls, walk word addresses 0..maxw through the maincpu port of
// sdram_narrow_bridge and accumulate the same term. rd_data must be in the
// loader's byte order -- psikyo_sdram_top passes cpu_rom_data_le, i.e. before
// its big-endian swap for the CPU.
module psk_romcheck (
	input  logic        clk,
	input  logic        reset,        // sdram_reset: aborts a running pass

	// loader write stream (rom_loader / pk_io_psk shape)
	input  logic        ldr_active,
	input  logic        ldr_req,
	input  logic        ldr_busy,
	input  logic [24:0] ldr_addr,     // BYTE address
	input  logic [15:0] ldr_data,

	// narrow-bridge read port (maincpu client, WORD address)
	output logic        rd_req,       // 1-clk pulse
	output logic [18:0] rd_addr,
	input  logic        rd_valid,
	input  logic [15:0] rd_data,

	output logic        busy,
	output logic        done,
	output logic        ok,
	output logic [31:0] wsum,
	output logic [31:0] rsum,
	output logic [19:0] words
);

	localparam logic [24:0] REGION_LIMIT = 25'h100000;   // 1MB = the 19-bit word range of cpu_rom_addr

	reg        ldr_active_d = 1'b0;
	reg        ldr_busy_d   = 1'b0;
	reg        pending      = 1'b0;
	reg        running      = 1'b0;
	reg [31:0] maxw         = 32'd0;
	reg [18:0] raddr        = 19'd0;
	reg        issued       = 1'b0;   // request for raddr already pulsed

	wire ldr_active_rise = ldr_active & ~ldr_active_d;
	wire ldr_active_fall = ~ldr_active & ldr_active_d;
	wire ldr_word_accept = ldr_active & ldr_req & ldr_busy & ~ldr_busy_d &&
						   (ldr_addr < REGION_LIMIT);

	// Word-address space actually written: highest word + 1, or 0 if none.
	wire [20:0] words_n = {1'b0, words} + 21'd1;

	always @(posedge clk) begin
		ldr_active_d <= ldr_active;
		ldr_busy_d   <= ldr_busy;

		// ---- read-request pulse, one per word address ----
		rd_req <= running & ~issued & ~reset;

		if (ldr_active_rise) begin
			wsum    <= 32'd0;
			rsum    <= 32'd0;
			words   <= 20'd0;
			maxw    <= 32'd0;
			done    <= 1'b0;
			ok      <= 1'b0;
			pending <= 1'b0;
			running <= 1'b0;
			raddr   <= 19'd0;
			issued  <= 1'b0;
		end else begin
			if (ldr_word_accept) begin
				wsum  <= wsum + {ldr_data ^ ldr_addr[16:1], ldr_data};
				words <= words + 20'd1;
				if ({12'd0, ldr_addr[20:1]} > maxw) maxw <= {12'd0, ldr_addr[20:1]};
			end

			if (ldr_active_fall) pending <= 1'b1;

			if (!reset) begin
				// start (or cancel a stale pending if the region is empty)
				if (pending && !running) begin
					pending <= 1'b0;
					raddr   <= 19'd0;
					issued  <= 1'b0;
					if (words_n == 0) done <= 1'b1;   // ok stays 0
					else              running <= 1'b1;
				end

				if (running) begin
					if (!issued) begin
						issued <= 1'b1;
					end else if (rd_valid) begin
						rsum <= rsum + {rd_data ^ raddr[15:0], rd_data};
						if ({13'd0, raddr} >= maxw) begin
							running <= 1'b0;
							done    <= 1'b1;
							ok      <= ((rsum + {rd_data ^ raddr[15:0], rd_data}) == wsum) &&
									   (words != 20'd0);
						end else begin
							raddr  <= raddr + 19'd1;
							issued <= 1'b0;
						end
					end
				end
			end
		end
	end

	assign rd_addr = raddr;
	assign busy    = pending | running;

endmodule
