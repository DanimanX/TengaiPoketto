// MIT License

// Copyright (c) 2022 Adam Gastineau

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////

// A very simple audio i2s bridge to APF, based on their example code
module sound_i2s #(
    parameter CHANNEL_WIDTH = 15,
    parameter SIGNED_INPUT  = 0
) (
    input wire clk_74a,
    input wire clk_audio,
    input wire ext_mclk,

    // Left and right audio channels. Can be in an arbitrary clock domain
    input wire [CHANNEL_WIDTH - 1:0] audio_l,
    input wire [CHANNEL_WIDTH - 1:0] audio_r,
    input wire                       audio_stb,

    output wire audio_mclk,
    output reg  audio_lrck = 1'b0,
    output reg  audio_dac  = 1'b0
);
  //
  // audio i2s generator (jitter-free PLL MCLK = 12.288 MHz)
  //
  assign audio_mclk = ext_mclk;

  // generate SCLK = 3.072 MHz by dividing ext_mclk (12.288 MHz) by 4
  reg [1:0] aud_mclk_divider = 2'd0;
  always @(posedge ext_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 2'd1;
  end
  wire audgen_sclk = aud_mclk_divider[1];

  // Format incoming 16-bit signed stereo sample
  localparam CHANNEL_LEFT_HIGH = SIGNED_INPUT ? 16 : 15;
  localparam CHANNEL_RIGHT_HIGH = 16 + CHANNEL_LEFT_HIGH;
  localparam SIGNED_CHANNEL_WIDTH = SIGNED_INPUT ? CHANNEL_WIDTH : CHANNEL_WIDTH + 1;

  wire [31:0] audgen_sampdata;

  assign audgen_sampdata[CHANNEL_LEFT_HIGH-1:CHANNEL_LEFT_HIGH-CHANNEL_WIDTH]   = audio_l;
  assign audgen_sampdata[CHANNEL_RIGHT_HIGH-1:CHANNEL_RIGHT_HIGH-CHANNEL_WIDTH] = audio_r;

  generate
    if (!SIGNED_INPUT) begin
      assign audgen_sampdata[31] = 0;
      assign audgen_sampdata[15] = 0;
    end
  endgenerate

  generate
    if (15 - SIGNED_CHANNEL_WIDTH > 0) begin
      assign audgen_sampdata[31-SIGNED_CHANNEL_WIDTH:16] = 0;
      assign audgen_sampdata[15-SIGNED_CHANNEL_WIDTH:0]  = 0;
    end
  endgenerate

  // Clean toggle-handshake CDC from clk_audio -> ext_mclk (0 M10K blocks)
  reg [31:0] samp_hold = 32'd0;
  reg        samp_tog  = 1'b0;

  always @(posedge clk_audio) begin
    if (audio_stb) begin
      samp_hold <= audgen_sampdata;
      samp_tog  <= ~samp_tog;
    end
  end

  reg        tog_s1 = 1'b0;
  reg        tog_s2 = 1'b0;
  reg        tog_s3 = 1'b0;
  reg [31:0] audgen_sampdata_s = 32'd0;

  always @(posedge ext_mclk) begin
    tog_s1 <= samp_tog;
    tog_s2 <= tog_s1;
    tog_s3 <= tog_s2;
    if (tog_s2 ^ tog_s3) begin
      audgen_sampdata_s <= samp_hold;
    end
  end

  reg [31:0] audgen_sampshift = 32'd0;
  reg [4:0]  audio_lrck_cnt   = 5'd0;
  reg        prev_audgen_sclk = 1'b0;

  always @(posedge ext_mclk) begin
    if (prev_audgen_sclk && ~audgen_sclk) begin
      // output the next bit on SCLK falling edge
      audio_dac <= audgen_sampshift[31];

      // 48 kHz * 64 = 3.072 MHz
      audio_lrck_cnt <= audio_lrck_cnt + 1'b1;
      if (audio_lrck_cnt == 31) begin
        // switch channels
        audio_lrck <= ~audio_lrck;

        // Reload sample shifter at start of Left channel
        if (~audio_lrck) begin
          audgen_sampshift <= audgen_sampdata_s;
        end
      end else if (audio_lrck_cnt < 16) begin
        // only shift for 16 clocks per channel
        audgen_sampshift <= {audgen_sampshift[30:0], 1'b0};
      end
    end

    prev_audgen_sclk <= audgen_sclk;
  end

  initial begin
    // Verify parameters
    if (CHANNEL_WIDTH > 16) begin
      $error("CHANNEL_WIDTH must be <= 16. Received %d", CHANNEL_WIDTH);
    end

    if (SIGNED_INPUT != 0 && SIGNED_INPUT != 1) begin
      $error("SIGNED_INPUT must be 0 or 1. Received %d", SIGNED_INPUT);
    end

    if (CHANNEL_WIDTH == 16 && SIGNED_INPUT == 0) begin
      $error("Cannot have CHANNEL_WIDTH of 16 and an unsigned input");
    end
  end
endmodule
