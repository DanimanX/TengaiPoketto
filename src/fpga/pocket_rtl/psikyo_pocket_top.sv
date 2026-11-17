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

	output reg  [16:0] sram_a = 17'd0,
	inout  wire [15:0] sram_dq,
	output reg         sram_oe_n = 1'b1,
	output reg         sram_we_n = 1'b1,
	output reg         sram_ub_n = 1'b1,
	output reg         sram_lb_n = 1'b1,

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
	wire reset = ~pll_locked | core_reset_btn | ~boot_done;

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
	reg  [15:0] wr_rdata = 16'd0;
	wire signed [15:0] snd_left, snd_right;
	wire        ioctl_wait_unused, ldr_busy_core;

	psikyo_top #(.BOARD_GUNBIRD(1'b0), .DEBUG_TRACER(1'b0), .EXT_WORKRAM(1'b1)) u_psikyo (
		.ext_workram_addr(wr_addr), .ext_workram_wel(wr_wel), .ext_workram_weh(wr_weh),
		.ext_workram_wdata(wr_wdata), .ext_workram_rdata(wr_rdata),
		.clk(clk_sys), .ce_pix(ce_pix), .reset(reset), .init(~pll_locked),

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

		.nmi_pending(nmi_pending),
		.snd_left(snd_left), .snd_right(snd_right),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb),

		.dbg_overlay(1'b0), .dbg_render_dis(3'd0), .pause(pause),
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(),
		.hs_read(1'b0), .hs_write(1'b0),
		.snd_irq_en(1'b1), .dbg_src(2'd0), .dbg_window(4'd0), .dbg_rearm(1'b0),
		.dbg_pixel()
	);

	// ---------------------------------------------------------------------
	// 5. 68020 work RAM in the async SRAM (64K x 16 of the 128K x 16 part)
	//    maincpu holds the address for the whole access, commits writes at
	//    acc_ph==1 (one-cycle wel/weh pulse) and, with EXT_WORKRAM, samples
	//    reads at acc_ph==3. Address/data/strobes are registered so they
	//    leave from the IOE; WE# is asserted the cycle AFTER the address is
	//    on the pins and released before it can change.
	// ---------------------------------------------------------------------
	reg  [15:0] sram_dout = 16'd0;
	reg         sram_drive = 1'b0;
	reg  [1:0]  wr_phase = 2'd0;
	assign sram_dq = sram_drive ? sram_dout : 16'hzzzz;

	always @(posedge clk_sys) begin
		sram_a    <= {1'b0, wr_addr};   // address on the pins from ph1 on
		wr_rdata  <= sram_dq;           // registered input, read at ph3
		case (wr_phase)
			2'd0: begin
				sram_we_n  <= 1'b1;
				sram_oe_n  <= 1'b0;
				sram_ub_n  <= 1'b0;
				sram_lb_n  <= 1'b0;
				sram_drive <= 1'b0;
				// wel/weh pulse at ph1: the address has been on the pins for
				// a cycle already; WE# low for one clk (11.6 ns), data driven
				// for two, and the address cannot change before ph3.
				if (wr_wel | wr_weh) begin
					sram_oe_n  <= 1'b1;
					sram_we_n  <= 1'b0;
					sram_drive <= 1'b1;
					sram_dout  <= wr_wdata;
					sram_ub_n  <= ~wr_weh;
					sram_lb_n  <= ~wr_wel;
					wr_phase   <= 2'd1;
				end
			end
			2'd1: begin sram_we_n <= 1'b1; wr_phase <= 2'd2; end
			default: begin wr_phase <= 2'd0; end   // data hold one more clk
		endcase
	end

	// ---------------------------------------------------------------------
	// 6. Video -> APF
	// ---------------------------------------------------------------------
	// Vertical games use scaler slot 1 (rotation 270), from .rom byte 24.
	reg [23:0] vid_rgb = 24'd0;
	reg        vid_de = 1'b0, vid_hs = 1'b0, vid_vs = 1'b0;
	reg        hsync_d = 1'b0, vsync_d = 1'b0;
	always @(posedge clk_sys) if (ce_pix) begin
		hsync_d <= hsync;
		vsync_d <= vsync;
		vid_hs  <= hsync & ~hsync_d;
		vid_vs  <= vsync & ~vsync_d;
		vid_de  <= ~hblank & ~vblank;
		if (~hblank & ~vblank)
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
