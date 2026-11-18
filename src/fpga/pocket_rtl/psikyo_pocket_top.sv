// psikyo_pocket_top: Psikyo 68k core (upstream psikyo_top) on the Analogue Pocket.
//
// Replaces upstream Psikyo.sv (the MiSTer glue). See PORTING.md for the design:
//   - psk_pll: exact 945 MHz VCO -> clk_sys 85.909 MHz / clk_pix 7.159 MHz
//   - pk_io_psk: APF data slot -> psikyo_top fast-loader port, pads, interact
//   - 68020 work RAM in the async SRAM (EXT_WORKRAM)
//   - SDRAM: upstream controller, clock pin = clk_sys inverted via DDIO
//   - video: RGB555 -> RGB888 to the APF scaler, slot 1 = rotated 270 for
//     the vertical games (board_gunbird / samurai aces / s1945 families)
//   - audio: sample-and-hold to the 48 kHz I2S DAC
`default_nettype none

module psikyo_pocket_top (
	input  wire        clk_74a,
	input  wire        apf_reset_n,
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,
	input  wire [31:0] cont1_key,
	input  wire [31:0] cont2_key,
	input  wire        apf_dataslot_complete,

	output wire [23:0] video_rgb,
	output wire        video_rgb_clock,
	output wire        video_rgb_clock_90,
	output wire        video_de,
	output wire        video_skip,
	output wire        video_vs,
	output wire        video_hs,

	output wire        audio_mclk,
	output wire        audio_lrck,
	output wire        audio_dac,

	output wire [12:0] dram_a,
	output wire [1:0]  dram_ba,
	inout  wire [15:0] dram_dq,
	output wire [1:0]  dram_dqm,
	output wire        dram_clk,
	output wire        dram_cke,
	output wire        dram_ras_n,
	output wire        dram_cas_n,
	output wire        dram_we_n,

	output wire [16:0] sram_a,
	inout  wire [15:0] sram_dq,
	output wire        sram_oe_n,
	output wire        sram_we_n,
	output wire        sram_ub_n,
	output wire        sram_lb_n,

	output wire        boot_done,
	output wire        pll_locked_o
);

	// ---------------------------------------------------------------------
	// 1. Clocks
	// ---------------------------------------------------------------------
	wire clk_sys, clk_pix, clk_pix_90, pll_locked;
	psk_pll u_pll (
		.refclk(clk_74a), .rst(1'b0),
		.clk_sys(clk_sys), .clk_pix(clk_pix), .clk_pix_90(clk_pix_90),
		.locked(pll_locked)
	);
	wire clk_audio_mclk, audio_pll_locked;
	psk_audio_pll u_audio_pll (
		.refclk(clk_74a), .rst(1'b0),
		.audio_mclk(clk_audio_mclk), .locked(audio_pll_locked)
	);
	assign pll_locked_o       = pll_locked;
	assign video_rgb_clock    = clk_pix;
	assign video_rgb_clock_90 = clk_pix_90;

	// SDRAM clock pin: clk_sys inverted (180 deg, as the MiSTer build's 5820 ps)
	altddio_out #(
		.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"),
		.invert_output("OFF"), .lpm_hint("UNUSED"), .lpm_type("altddio_out"),
		.oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
	) u_dram_clk (
		.datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sys), .dataout(dram_clk),
		.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1),
		.sclr(1'b0), .sset(1'b0), .oe_out()
	);

	// ce_pix: exact 1-in-12 of clk_sys (= clk_pix), as upstream
	reg [3:0] ce_pix_cnt = 4'd0;
	wire      ce_pix = (ce_pix_cnt == 4'd0);
	always @(posedge clk_sys) ce_pix_cnt <= (ce_pix_cnt == 4'd11) ? 4'd0 : ce_pix_cnt + 4'd1;

	// ---------------------------------------------------------------------
	// 2. APF adapter
	// ---------------------------------------------------------------------
	wire [31:0] joystick_0, joystick_1;
	wire        core_reset_btn, fifo_ovf;
	wire [1:0]  audio_vol;
	wire [1:0]  sdram_cap_sel;
	wire        dbg_overlay, dbg_rearm;
	wire [1:0]  dbg_src;
	wire [23:0] dbg_pixel;
	wire [7:0]  mod_board;
	wire        vertical;
	wire [63:0] dip_rom, dip_sw;
	wire        mcu_table_we;
	wire [7:0]  mcu_table_waddr, mcu_table_wdata;
	wire        ldr_active, ldr_req, ldr_we16, ldr_busy;
	wire [24:0] ldr_addr;
	wire [15:0] ldr_data;

	pk_io_psk u_io (
		.clk_74a(clk_74a), .apf_reset_n(apf_reset_n),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
		.cont1_key(cont1_key), .cont2_key(cont2_key),
		.apf_dataslot_complete(apf_dataslot_complete),
		.clk_sys(clk_sys), .pll_locked(pll_locked),
		.joystick_0(joystick_0), .joystick_1(joystick_1),
		.core_reset_btn(core_reset_btn), .audio_vol(audio_vol),
		.sdram_cap_sel(sdram_cap_sel),
		.dbg_overlay(dbg_overlay), .dbg_src(dbg_src), .dbg_rearm(dbg_rearm),
		.board_flags(mod_board), .vertical(vertical), .dip_sw(dip_rom), .dip_eff(dip_sw),
		.mcu_table_we(mcu_table_we), .mcu_table_waddr(mcu_table_waddr),
		.mcu_table_wdata(mcu_table_wdata),
		.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
		.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),
		.boot_done(boot_done), .fifo_ovf(fifo_ovf)
	);

	// board flags (Psikyo.sv: .mra index 1 byte 0)
	wire board_gunbird     = mod_board[0];
	wire needs_adpcma_swap = mod_board[1];
	wire snd_latch_c00011  = mod_board[2];
	wire board_sh404       = mod_board[3];
	wire mcu_table_absent  = mod_board[4];

	// Hold the game in reset until a ROM has loaded. The SDRAM backend has
	// its own reset (init) and stays alive for the load, as upstream requires.
	// bist_busy: the power-up SRAM self-test owns the work RAM (section 5)
	wire bist_busy;
	wire reset = ~pll_locked | core_reset_btn | ~boot_done | bist_busy;

	// ---------------------------------------------------------------------
	// 3. Inputs (verbatim layout from Psikyo.sv)
	// ---------------------------------------------------------------------
	wire nmi_pending;
	wire [8:0] hcnt, vcnt;
	wire hblank, vblank, hsync, vsync;
	wire [14:0] rgb;

	wire [15:0] p1p2_low = board_gunbird
		? {~joystick_0[7], ~joystick_0[8], ~joystick_0[9], 1'b1,
		   ~joystick_1[7], ~joystick_1[8], ~joystick_1[9], 1'b1,
		   nmi_pending, 1'b1, 1'b1, 1'b1, 2'b11,
		   ~joystick_1[11], ~joystick_0[11]}
		: 16'hFFFF;

	wire [31:0] p1p2_in = {
		~joystick_0[3], ~joystick_0[2], ~joystick_0[0], ~joystick_0[1],
		~joystick_0[4], ~joystick_0[5], ~joystick_0[6], ~joystick_0[10],
		~joystick_1[3], ~joystick_1[2], ~joystick_1[0], ~joystick_1[1],
		~joystick_1[4], ~joystick_1[5], ~joystick_1[6], ~joystick_1[10],
		p1p2_low
	};

	// Service: forces the DIP "Service Mode" switch (bit 7, On = 0)
	wire        service = joystick_0[12];
	wire [7:0]  dip_b0  = {dip_sw[7] & ~service, dip_sw[6:0]};
	wire [31:0] dsw_in  = {dip_sw[15:8], dip_b0, 8'hFF, dip_sw[23:16]};

	wire [31:0] coin_in = {
		8'hFF, nmi_pending, 5'h1F,
		board_gunbird ? 2'b11 : {~joystick_1[11], ~joystick_0[11]},
		15'h7FFF, 1'b0
	};

	// Pause toggles on joystick bit 13 (R2 or Start+Select)
	reg pause = 1'b0, pause_btn_d = 1'b0;
	always @(posedge clk_sys) begin
		pause_btn_d <= joystick_0[13];
		if (reset) pause <= 1'b0;
		else if (joystick_0[13] & ~pause_btn_d) pause <= ~pause;
	end

	// ---------------------------------------------------------------------
	// 4. Core
	// ---------------------------------------------------------------------
	wire [15:0] wr_addr, wr_wdata;
	wire        wr_wel, wr_weh;
	wire [15:0] wr_rdata;
	wire signed [15:0] snd_left, snd_right;
	wire        ioctl_wait_unused, ldr_busy_core;
	wire        chk_busy, chk_done, chk_ok;
	wire [31:0] chk_wsum, chk_rsum;
	wire [19:0] chk_words;

	psikyo_top #(.BOARD_GUNBIRD(1'b0), .DEBUG_TRACER(1'b0), .EXT_WORKRAM(1'b1)) u_psikyo (
		.ext_workram_addr(wr_addr), .ext_workram_wel(wr_wel), .ext_workram_weh(wr_weh),
		.ext_workram_wdata(wr_wdata), .ext_workram_rdata(wr_rdata),
		.clk(clk_sys), .sdram_cap_sel(sdram_cap_sel),
		.ce_pix(ce_pix), .reset(reset), .init(~pll_locked),

		.SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]),
		.SDRAM_BA(dram_ba), .SDRAM_nCS(), .SDRAM_nWE(dram_we_n),
		.SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
		.SDRAM_CLK(), .SDRAM_CKE(dram_cke), .SDRAM_DQ(dram_dq),

		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
		.ioctl_addr(25'd0), .ioctl_dout(8'd0), .ioctl_wait(ioctl_wait_unused),

		.p1p2_in(p1p2_in), .dsw_in(dsw_in), .coin_in(coin_in),
		.board_gunbird(board_gunbird), .board_sh404(board_sh404),
		.snd_latch_c00011(snd_latch_c00011), .mcu_table_absent(mcu_table_absent),
		.mcu_table_we(mcu_table_we), .mcu_table_waddr(mcu_table_waddr),
		.mcu_table_wdata(mcu_table_wdata), .needs_adpcma_swap(needs_adpcma_swap),

		.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
		.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),

		.chk_busy(chk_busy), .chk_done(chk_done), .chk_ok(chk_ok),
		.chk_wsum(chk_wsum), .chk_rsum(chk_rsum), .chk_words(chk_words),

		.nmi_pending(nmi_pending),
		.snd_left(snd_left), .snd_right(snd_right),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb),

		.dbg_overlay(dbg_overlay), .dbg_render_dis(3'd0), .pause(pause),
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(),
		.hs_read(1'b0), .hs_write(1'b0),
		.snd_irq_en(1'b1), .dbg_src(dbg_src), .dbg_window(4'd0), .dbg_rearm(dbg_rearm),
		.dbg_pixel(dbg_pixel)
	);

	// ---------------------------------------------------------------------
	// 5. 68020 work RAM in the async SRAM (64K x 16 of the 128K x 16 part)
	//    The CPU address is only settled at the end of acc_ph 1 (kernel paths
	//    are -setup 2). maincpu pulses wel/weh at acc_ph==1, acks writes at
	//    acc_ph==3 and, with EXT_WORKRAM, captures reads at acc_ph==4.
	//    psk_sram latches the write, drops WE# a clk after the settled address
	//    is on the pins, and keeps its data driver and the SRAM's OE# apart
	//    by a clk. All pin registers are in the IOE. Timeline: psk_sram.sv.
	// ---------------------------------------------------------------------
	// Power-up self-test (psk_sram_bist.sv): runs once after configuration,
	// during the ROM load, and holds the core in reset until it is done.
	wire [15:0] b_addr, b_wdata;
	wire        b_wel, b_weh, b_slow;
	wire [1:0]  bist_done;
	wire [15:0] bist_err0, bist_err1, bist_fa0, bist_fg0, bist_fe0,
				bist_fa1, bist_fg1, bist_fe1, bist_raw0, bist_raw1;
	psk_sram_bist u_bist (
		.clk(clk_sys), .start(pll_locked), .busy(bist_busy),
		.b_addr(b_addr), .b_wel(b_wel), .b_weh(b_weh), .b_wdata(b_wdata),
		.b_slow(b_slow), .b_rdata(wr_rdata),
		.done(bist_done), .err0(bist_err0), .err1(bist_err1),
		.fa0(bist_fa0), .fg0(bist_fg0), .fe0(bist_fe0),
		.fa1(bist_fa1), .fg1(bist_fg1), .fe1(bist_fe1),
		.raw0(bist_raw0), .raw1(bist_raw1)
	);

	psk_sram u_sram (
		.clk(clk_sys), .slow(b_slow),
		.wr_addr(bist_busy ? b_addr : wr_addr),
		.wr_wel(bist_busy ? b_wel : wr_wel), .wr_weh(bist_busy ? b_weh : wr_weh),
		.wr_wdata(bist_busy ? b_wdata : wr_wdata), .wr_rdata(wr_rdata),
		.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n),
		.sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
	);

	// ---------------------------------------------------------------------
	// 6. Video -> APF
	// ---------------------------------------------------------------------
	// Vertical games use scaler slot 1 (rotation 270), from .rom byte 24.
	reg [23:0] vid_rgb = 24'd0;
	reg        vid_de = 1'b0, vid_hs = 1'b0, vid_vs = 1'b0;
	reg        hsync_d = 1'b0, vsync_d = 1'b0;

	// Diagnostic overlay: 10 bands of 8 lines from the top of the visible
	// area, 32-bit fields at 8 px per bit, MSB first (yellow 1 / blue 0):
	//   0 ROM check status (grey running, green ok, red mismatch)
	//   1 rsum   2 wsum   3 words
	//   4 SRAM BIST status: left half slow mode, right half normal mode
	//   5 {slow errors, normal errors}   (saturating at FFFF)
	//   6 normal: {first fail addr, got}   7 normal: {expected, raw word 0}
	//   8 slow:   {first fail addr, got}   9 slow:   {expected, raw word 0}
	reg [6:0]  vis_line = 7'd0;
	reg [8:0]  vis_px   = 9'd0;
	reg        hblank_d = 1'b0;
	wire [3:0] band = vis_line[6:3];
	// Shown only when a self-test FAILED, so a healthy load shows just the
	// game. A check still running counts as not failed.
	wire       diag_fail  = (chk_done & ~chk_ok) |
	                        (bist_done[0] & (bist_err0 != 16'd0)) |
	                        (bist_done[1] & (bist_err1 != 16'd0));
	wire       overlay_on = diag_fail & ~hblank & ~vblank & (vis_line < 7'd80);
	reg [31:0] ovl_field;
	always @(*) begin
		case (band)
			4'd1: ovl_field = chk_rsum;
			4'd2: ovl_field = chk_wsum;
			4'd3: ovl_field = {12'd0, chk_words};
			4'd5: ovl_field = {bist_err0, bist_err1};
			4'd6: ovl_field = {bist_fa1, bist_fg1};
			4'd7: ovl_field = {bist_fe1, bist_raw1};
			4'd8: ovl_field = {bist_fa0, bist_fg0};
			4'd9: ovl_field = {bist_fe0, bist_raw0};
			default: ovl_field = 32'h0;
		endcase
	end
	wire       ovl_bit   = ovl_field[31 - vis_px[7:3]];
	wire       bist_m    = vis_px >= 9'd160;            // band 4: which mode
	wire       bist_md   = bist_m ? bist_done[1] : bist_done[0];
	wire       bist_mok  = bist_m ? (bist_err1 == 16'd0) : (bist_err0 == 16'd0);
	reg [23:0] ovl_rgb;
	always @(*) begin
		if (band == 4'd0)
			ovl_rgb = chk_done ? (chk_ok ? 24'h00FF00 : 24'hFF0000) : 24'h808080;
		else if (band == 4'd4)
			ovl_rgb = (vis_px == 9'd159) ? 24'h000000 :
					  !bist_md ? 24'h808080 : (bist_mok ? 24'h00FF00 : 24'hFF0000);
		else if (vis_px >= 9'd256)
			ovl_rgb = 24'h000000;
		else if (vis_px[2:0] == 3'd0)
			ovl_rgb = 24'h000000;
		else
			ovl_rgb = ovl_bit ? 24'hFFFF00 : 24'h0000FF;
	end

	wire [2:0]  dbg_trip = dbg_pixel[23 - 3*hcnt[5:3] -: 3];
	wire [23:0] dbg_bits = {{8{dbg_trip[2]}}, {8{dbg_trip[1]}}, {8{dbg_trip[0]}}};

	always @(posedge clk_sys) if (ce_pix) begin
		hsync_d <= hsync;
		vsync_d <= vsync;
		vid_hs  <= hsync & ~hsync_d;
		vid_vs  <= vsync & ~vsync_d;
		vid_de  <= ~hblank & ~vblank;

		// line/pixel counters for the overlay (hblank falling start of line)
		hblank_d <= hblank;
		if (vblank) begin
			vis_line <= 7'd0;
			vis_px   <= 9'd0;
		end else begin
			if (hblank_d & ~hblank && vis_line != 7'd127) vis_line <= vis_line + 7'd1;   // saturate: overlay only once per frame
			if (hblank) vis_px <= 9'd0;
			else        vis_px <= vis_px + 9'd1;
		end

		// Debug tracer: whole frame is raw 24-bit data, one value per pixel
		// (layout: rtl/psikyo_core.sv g_tracer; decode the Memories PNG
		// with upstream scripts/decode_debug_screenshot.py)
		// Rows 0-63 (VRAM/vregs/palette dumps) change value every pixel and
		// stay raw. Rows 64+ hold ONE value per line, which Pocket screenshots
		// do not preserve raw (~5 bits per channel plus dithering), so it is
		// sent as saturated bits: 8 blocks of 8 px, 3 bits per block (R,G,B =
		// bit 23-3k, 22-3k, 21-3k for block k = hcnt[5:3]), repeated every 64 px.
		if (dbg_overlay & ~hblank & ~vblank)
			vid_rgb <= (vcnt < 9'd64) ? dbg_pixel : dbg_bits;
		else if (overlay_on)
			vid_rgb <= ovl_rgb;
		else if (~hblank & ~vblank)
			vid_rgb <= {rgb[14:10], rgb[14:12], rgb[9:5], rgb[9:7], rgb[4:0], rgb[4:2]};
		else
			vid_rgb <= {11'd0, 10'(vertical ? 1 : 0), 3'd0};   // scaler slot word
	end
	assign video_rgb  = vid_rgb;
	assign video_de   = vid_de;
	assign video_hs   = vid_hs;
	assign video_vs   = vid_vs;
	assign video_skip = 1'b0;

	// ---------------------------------------------------------------------
	// 7. Audio: hold to 48 kHz, volume, I2S
	// ---------------------------------------------------------------------
	reg [31:0] aud_acc = 32'd0;
	reg        aud_stb = 1'b0;
	localparam [31:0] F_SYS = 32'd85909091;
	always @(posedge clk_sys) begin
		aud_stb <= 1'b0;
		if (aud_acc + 32'd48000 >= F_SYS) begin
			aud_acc <= aud_acc + 32'd48000 - F_SYS;
			aud_stb <= 1'b1;
		end else aud_acc <= aud_acc + 32'd48000;
	end

	wire [1:0] sh = audio_vol;   // 0: 1x, 1: 2x, 2: 4x
	wire signed [17:0] wl = 18'($signed(snd_left))  <<< sh;
	wire signed [17:0] wr = 18'($signed(snd_right)) <<< sh;
	reg  signed [15:0] out_l = 16'sd0, out_r = 16'sd0;
	always @(posedge clk_sys) if (aud_stb) begin
		out_l <= (wl > 18'sd32767) ? 16'sd32767 : (wl < -18'sd32768) ? -16'sd32768 : wl[15:0];
		out_r <= (wr > 18'sd32767) ? 16'sd32767 : (wr < -18'sd32768) ? -16'sd32768 : wr[15:0];
	end
	reg aud_stb_d = 1'b0;
	always @(posedge clk_sys) aud_stb_d <= aud_stb;

	sound_i2s #(.CHANNEL_WIDTH(16), .SIGNED_INPUT(1)) u_i2s (
		.clk_74a(clk_74a), .clk_audio(clk_sys), .ext_mclk(clk_audio_mclk),
		.audio_l(out_l), .audio_r(out_r), .audio_stb(aud_stb_d),
		.audio_mclk(audio_mclk), .audio_lrck(audio_lrck), .audio_dac(audio_dac)
	);

endmodule
`default_nettype wire
