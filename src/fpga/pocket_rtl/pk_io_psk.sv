// pk_io_psk: APF bridge / pad / interact adapter for TengaiPoketto.
//
// ROM slot (data slot 1, bridge address 0x0000_0000) carries a .rom image
// built by tools/build_rom.py (PORTING.md section 7):
//   0x000  magic "PSK\x01"
//   0x004  {blob_len[15:0], version[7:0], board_flags[7:0]}   (LE fields)
//   0x008  payload length        0x00C  payload CRC32
//   0x010  DIP bytes 0-3         0x014  DIP bytes 4-7
//   0x018  byte 0: rotation (1 = vertical game -> rotated scaler slot)
//   0x020..0x21F  board blob (byte 0 = flags, bytes 4..259 = SH404 MCU table)
//   0x220..       SDRAM image (MiSTer .mra index 0 stream)
// bridge_endian_little = 1, so a bridge word is {b3,b2,b1,b0} of the file.
//
// The SDRAM image goes straight to psikyo_top's fast-loader port (ldr_*,
// 16-bit writes, the path upstream uses for its DDR3 copy), so nothing in
// the core changes. Bridge writes have no back-pressure: words cross into
// clk_sys through a 2048-deep dcfifo that also carries the bridge address,
// so a dropped word leaves a hole rather than shifting the image.
`default_nettype none

module pk_io_psk #(
	parameter [31:0] INTERACT_BASE = 32'hF000_0000,
	parameter [24:0] ADPCMA_BASE   = 25'h0E40000
) (
	// ---- APF side (clk_74a) ----
	input  wire        clk_74a,
	input  wire        apf_reset_n,
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,
	input  wire [31:0] cont1_key,
	input  wire [31:0] cont2_key,
	input  wire        apf_dataslot_complete,

	// ---- core side (clk_sys) ----
	input  wire        clk_sys,
	input  wire        pll_locked,

	output reg  [31:0] joystick_0 = 32'd0,
	output reg  [31:0] joystick_1 = 32'd0,
	output reg         core_reset_btn = 1'b0,
	output reg  [1:0]  audio_vol = 2'd1,
	output reg  [1:0]  sdram_cap_sel = 2'd0,   // SDRAM read capture point
	output reg         dbg_overlay = 1'b0,     // debug tracer overlay (menu)
	output reg  [1:0]  dbg_src = 2'd0,         // tracer mode: [0] ring, [1] freeze on trigger
	output reg         dbg_rearm = 1'b0,       // toggles on each menu re-arm

	output reg  [7:0]  board_flags = 8'd0,
	output reg         vertical = 1'b0,     // .rom header byte 24
	output reg  [63:0] dip_sw = 64'hFFFF_FFFF_FFFF_FFFF,   // .rom defaults
	output reg  [63:0] dip_eff = 64'hFFFF_FFFF_FFFF_FFFF,  // + menu overrides

	output reg         mcu_table_we = 1'b0,
	output reg  [7:0]  mcu_table_waddr = 8'd0,
	output reg  [7:0]  mcu_table_wdata = 8'd0,

	output reg         ldr_active = 1'b0,
	output wire        ldr_req,
	output reg  [24:0] ldr_addr = 25'd0,
	output wire [15:0] ldr_data,
	output wire        ldr_we16,
	input  wire        ldr_busy,

	output reg         boot_done = 1'b0,
	output reg         fifo_ovf = 1'b0
);

	// ---------------------------------------------------------------------
	// 1. interact.json registers (clk_74a)
	// ---------------------------------------------------------------------
	reg       reset_tog_74 = 1'b0;
	reg       service_74   = 1'b0;
	reg [2:0] diff_74      = 3'd0;   // 0 = .rom default, 1..4 = Easy..Hardest
	reg [2:0] lives_74     = 3'd0;   // 0 = default, 1..4 lives
	reg [1:0] demo_74      = 2'd0;   // 0 = default, 1 = off, 2 = on
	reg [1:0] vol_74       = 2'd1;
	reg [1:0] sdcap_74     = 2'd0;
	reg       dbgovl_74    = 1'b0;
	reg [1:0] dbgsrc_74    = 2'd0;
	reg       rearm_74     = 1'b0;
	reg       apf_reset_n_d = 1'b0;

	// list values arrive in either byte order (bridge_endian_little)
	wire [7:0] wv = bridge_wr_data[7:0] | bridge_wr_data[31:24];

	always @(posedge clk_74a) begin
		apf_reset_n_d <= apf_reset_n;
		if (apf_reset_n && !apf_reset_n_d) reset_tog_74 <= ~reset_tog_74;
		else if (bridge_wr) begin
			case (bridge_addr)
				INTERACT_BASE + 32'h00: if (wv[0]) reset_tog_74 <= ~reset_tog_74;
				INTERACT_BASE + 32'h04: service_74 <= wv[0];
				INTERACT_BASE + 32'h08: vol_74     <= wv[1:0];
				INTERACT_BASE + 32'h10: diff_74    <= wv[2:0];
				INTERACT_BASE + 32'h14: lives_74   <= wv[2:0];
				INTERACT_BASE + 32'h18: demo_74    <= wv[1:0];
				INTERACT_BASE + 32'h1C: sdcap_74   <= wv[1:0];
				INTERACT_BASE + 32'h20: dbgovl_74  <= wv[0];
				INTERACT_BASE + 32'h24: dbgsrc_74  <= wv[1:0];
				INTERACT_BASE + 32'h28: if (wv[0]) rearm_74 <= ~rearm_74;
				default: ;
			endcase
		end
	end

	reg [2:0]  rst_sync = 3'd0;
	reg [1:0]  srv_sync = 2'd0;
	reg [15:0] rst_stretch = 16'd0;
	reg [2:0]  diff_s = 3'd0, lives_s = 3'd0;
	reg [1:0]  demo_s = 2'd0;
	always @(posedge clk_sys) begin
		rst_sync <= {rst_sync[1:0], reset_tog_74};
		srv_sync <= {srv_sync[0], service_74};
		diff_s   <= diff_74;      // quasi-static menu values
		lives_s  <= lives_74;
		demo_s   <= demo_74;
		audio_vol <= vol_74;
		sdram_cap_sel <= sdcap_74;
		dbg_overlay <= dbgovl_74;   // quasi-static; the tracer only needs a level change
		dbg_src     <= dbgsrc_74;
		dbg_rearm   <= rearm_74;
		if (rst_sync[2] ^ rst_sync[1]) rst_stretch <= 16'hFFFF;
		else if (rst_stretch != 16'd0) rst_stretch <= rst_stretch - 16'd1;
		core_reset_btn <= (rst_stretch != 16'd0);
	end

	// ---------------------------------------------------------------------
	// 2. ROM slot -> dcfifo (clk_74a -> clk_sys)
	// ---------------------------------------------------------------------
	wire        slot_wr  = bridge_wr && (bridge_addr < 32'h0800_0000);
	wire [56:0] fifo_din = {bridge_addr[26:2], bridge_wr_data};
	wire [56:0] fifo_q;
	wire        fifo_empty, fifo_full;
	reg         fifo_rd = 1'b0;

	reg fifo_ovf_74 = 1'b0;
	always @(posedge clk_74a) begin
		if (slot_wr && bridge_addr == 32'h0)  fifo_ovf_74 <= 1'b0;   // new load
		else if (slot_wr && fifo_full)        fifo_ovf_74 <= 1'b1;
	end
	reg [1:0] ovf_sync = 2'd0;
	always @(posedge clk_sys) begin
		ovf_sync <= {ovf_sync[0], fifo_ovf_74};
		fifo_ovf <= ovf_sync[1];
	end

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(2048),
		.lpm_showahead("OFF"),
		.lpm_type("dcfifo"),
		.lpm_width(57),
		.lpm_widthu(11),
		.overflow_checking("ON"),
		.underflow_checking("ON"),
		.use_eab("ON")
	) rom_fifo (
		.data(fifo_din), .wrclk(clk_74a), .wrreq(slot_wr),
		.rdclk(clk_sys), .rdreq(fifo_rd), .q(fifo_q),
		.rdempty(fifo_empty), .wrfull(fifo_full),
		.aclr(1'b0), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	reg [1:0] dsc_sync = 2'd0;
	always @(posedge clk_sys) dsc_sync <= {dsc_sync[0], apf_dataslot_complete};

	// ---------------------------------------------------------------------
	// 3. Loader FSM (clk_sys)
	// ---------------------------------------------------------------------
	localparam [3:0]
		S_IDLE   = 4'd0,  S_POP   = 4'd1,  S_WAIT  = 4'd2,  S_DISP = 4'd3,
		S_BLOB   = 4'd4,  S_WR_LO = 4'd5,  S_ACK_LO = 4'd6,
		S_WR_HI  = 4'd7,  S_ACK_HI = 4'd8, S_DONE  = 4'd9;

	reg  [3:0]  st = S_IDLE;
	reg  [31:0] w = 32'd0;          // current bridge word
	reg  [26:0] wa = 27'd0;         // its byte address in the .rom file
	reg  [15:0] blob_len = 16'd0;
	reg  [1:0]  bidx = 2'd0;        // byte within the word, blob phase
	reg  [7:0]  idle_cnt = 8'd0;
	reg  [15:0] ldr_word = 16'd0;
	reg         seen_hdr = 1'b0;

	assign ldr_req  = (st == S_WR_LO) || (st == S_WR_HI);
	assign ldr_we16 = 1'b1;

	// samuraia/sngkace ADPCM-A bit 6/7 swap, per byte, inside the 1 MB window
	// (done by rom_loader.sv on the MiSTer fast path, so it has to be here).
	wire in_adpcma = (ldr_addr >= ADPCMA_BASE) && (ldr_addr < ADPCMA_BASE + 25'h100000);
	assign ldr_data = (board_flags[1] && in_adpcma)
		? {ldr_word[14], ldr_word[15], ldr_word[13:8], ldr_word[6], ldr_word[7], ldr_word[5:0]}
		: ldr_word;

	wire [26:0] blob_off = wa - 27'h20 + {25'd0, bidx};

	always @(posedge clk_sys or negedge pll_locked) begin
		if (!pll_locked) begin
			st <= S_IDLE; fifo_rd <= 1'b0; ldr_active <= 1'b0; boot_done <= 1'b0;
			mcu_table_we <= 1'b0; seen_hdr <= 1'b0;
		end else begin
			fifo_rd      <= 1'b0;
			mcu_table_we <= 1'b0;

			case (st)
				S_IDLE, S_POP: begin
					if (!fifo_empty) begin
						fifo_rd  <= 1'b1;
						idle_cnt <= 8'd0;
						st       <= S_WAIT;
					end else if (st == S_POP && dsc_sync[1]) begin
						// slot complete and FIFO drained (debounced)
						if (&idle_cnt) st <= S_DONE;
						else idle_cnt <= idle_cnt + 8'd1;
					end
				end

				S_WAIT: st <= S_DISP;            // dcfifo registered output

				S_DISP: begin
					w  <= fifo_q[31:0];
					wa <= {fifo_q[56:32], 2'b00};
					st <= S_POP;
					case ({fifo_q[56:32], 2'b00})
						27'h000: begin                // magic: start of a load
							ldr_active <= 1'b1;
							boot_done  <= 1'b0;
							seen_hdr   <= 1'b1;
						end
						27'h004: begin
							board_flags <= fifo_q[7:0];
							blob_len    <= fifo_q[31:16];
						end
						27'h010: dip_sw[31:0]  <= fifo_q[31:0];
						27'h014: dip_sw[63:32] <= fifo_q[31:0];
						27'h018: vertical      <= fifo_q[0];
						default: begin
							if ({fifo_q[56:32], 2'b00} >= 27'h220) begin
								ldr_addr <= 25'({fifo_q[56:32], 2'b00} - 27'h220);
								ldr_word <= fifo_q[15:0];
								st       <= S_WR_LO;
							end else if ({fifo_q[56:32], 2'b00} >= 27'h020) begin
								bidx <= 2'd0;
								st   <= S_BLOB;
							end
						end
					endcase
				end

				// board blob: bytes 4..259 are the SH404 MCU table
				// (Psikyo.sv: ioctl index 1, addr 4..259 -> table addr-4)
				S_BLOB: begin
					if (blob_off < {11'd0, blob_len} && blob_off >= 27'd4 && blob_off < 27'd260) begin
						mcu_table_we    <= 1'b1;
						mcu_table_waddr <= 8'(blob_off - 27'd4);
						mcu_table_wdata <= w[{bidx, 3'b000} +: 8];
					end
					bidx <= bidx + 2'd1;
					if (bidx == 2'd3) st <= S_POP;
				end

				// two 16-bit SDRAM writes per bridge word; hold req until the
				// arbiter takes it (busy high), then wait for it to free up
				S_WR_LO:  if (ldr_busy) st <= S_ACK_LO;
				S_ACK_LO: if (!ldr_busy) begin
					ldr_addr <= ldr_addr + 25'd2;
					ldr_word <= w[31:16];
					st       <= S_WR_HI;
				end
				S_WR_HI:  if (ldr_busy) st <= S_ACK_HI;
				S_ACK_HI: if (!ldr_busy) st <= S_POP;

				S_DONE: begin
					ldr_active <= 1'b0;
					boot_done  <= seen_hdr;
					st         <= S_IDLE;   // a later load restarts cleanly
				end
				default: st <= S_IDLE;
			endcase
		end
	end

	// ---------------------------------------------------------------------
	// 4. DIP overrides from the interact menu. DIP byte 0 is the same on the
	//    shoot'em-ups (upstream .mra <switches>): bit1 Demo Sounds (On=0),
	//    bits 3:2 Difficulty (Hardest,Hard,Easy,Normal = 0..3), bits 5:4
	//    Lives (4,2,1,3 = 0..3). A menu value of 0 keeps the .rom default, so
	//    games with a different layout (Battle K-Road) are untouched as long
	//    as the menu stays on Default.
	// ---------------------------------------------------------------------
	reg [1:0] diff_code, lives_code;
	always @(*) begin
		case (diff_s)
			3'd1: diff_code = 2'd2;   // Easy
			3'd2: diff_code = 2'd3;   // Normal
			3'd3: diff_code = 2'd1;   // Hard
			default: diff_code = 2'd0; // Hardest
		endcase
		case (lives_s)
			3'd1: lives_code = 2'd2;  // 1
			3'd2: lives_code = 2'd1;  // 2
			3'd3: lives_code = 2'd3;  // 3
			default: lives_code = 2'd0; // 4
		endcase
	end
	always @(posedge clk_sys) begin
		dip_eff <= dip_sw;
		if (diff_s  != 3'd0) dip_eff[3:2] <= diff_code;
		if (lives_s != 3'd0) dip_eff[5:4] <= lives_code;
		if (demo_s  != 2'd0) dip_eff[1]   <= (demo_s == 2'd1);  // Off = 1
	end

	// ---------------------------------------------------------------------
	// 5. Pads -> MiSTer joystick layout used by Psikyo.sv
	//    [0]R [1]L [2]D [3]U [4]B1 [5]B2 [6]B3 [7]B4 [8]B5 [9]B6
	//    [10]Start [11]Coin [12]Service [13]Pause
	//    APF: [0]up [1]down [2]left [3]right [4]a [5]b [6]x [7]y
	//         [8]l1 [9]r1 [10]l2 [11]r2 [14]select [15]start
	// ---------------------------------------------------------------------
	function automatic [31:0] map_pad(input [31:0] k, input svc);
		map_pad = 32'd0;
		map_pad[0]  = k[3];
		map_pad[1]  = k[2];
		map_pad[2]  = k[1];
		map_pad[3]  = k[0];
		map_pad[4]  = k[7];          // Y  -> Button 1 (shot)
		map_pad[5]  = k[5];          // B  -> Button 2 (bomb)
		map_pad[6]  = k[4];          // A  -> Button 3
		map_pad[7]  = k[6];          // X  -> Button 4
		map_pad[8]  = k[8];          // L  -> Button 5
		map_pad[9]  = k[9];          // R  -> Button 6
		map_pad[10] = k[15] & ~k[14];
		map_pad[11] = k[14] & ~k[15];
		map_pad[12] = k[10] | svc;
		map_pad[13] = k[11] | (k[15] & k[14]);
	endfunction

	reg [31:0] k1_s = 32'd0, k2_s = 32'd0;
	always @(posedge clk_sys) begin
		k1_s <= cont1_key;           // slow buttons: one register is enough
		k2_s <= cont2_key;
		joystick_0 <= map_pad(k1_s, srv_sync[1]);
		joystick_1 <= map_pad(k2_s, 1'b0);
	end

endmodule
`default_nettype wire
