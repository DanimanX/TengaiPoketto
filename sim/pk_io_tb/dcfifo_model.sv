// Behavioral model of Altera's `dcfifo` megafunction, matching the parameter
// set and port list pk_io_psk.sv instantiates.
//
// Semantics modelled:
//   * lpm_showahead "OFF": q is a register updated on the rdclk edge where
//     rdreq is high (data available on the following cycle).
//   * wrfull / rdempty are computed against a 2-stage synchroniser of the
//     opposite-domain pointer, i.e. they are conservative (full may assert up
//     to 2 wrclk edges early and clear late, empty may deassert up to 2 rdclk
//     edges late).  That never loses or duplicates a word; it only moves the
//     flag transition.
//   * A shared word array stands in for the dual-port M10K; gray coding and
//     ECC are not modelled.
`timescale 1ns/1ps
`default_nettype none

module dcfifo #(
	parameter intended_device_family = "Unspecified",
	parameter lpm_numwords = 2048,
	parameter lpm_showahead = "OFF",
	parameter lpm_type = "dcfifo",
	parameter lpm_width = 1,
	parameter lpm_widthu = 1,
	parameter overflow_checking = "ON",
	parameter underflow_checking = "ON",
	parameter use_eab = "ON"
) (
	input  wire                  wrclk,
	input  wire                  wrreq,
	input  wire [lpm_width-1:0]  data,
	input  wire                  rdclk,
	input  wire                  rdreq,
	output reg  [lpm_width-1:0]  q,
	output reg                   rdempty,
	output reg                   wrfull,
	input  wire                  aclr,
	output wire                  eccstatus,
	output wire                  rdfull,
	output wire [lpm_widthu-1:0] rdusedw,
	output wire                  wrempty,
	output wire [lpm_widthu-1:0] wrusedw
);

	localparam PTRW = lpm_widthu + 1;   // one extra bit: distinguishes full/empty

	reg [lpm_width-1:0] mem [0:lpm_numwords-1];

	reg [PTRW-1:0] wrptr = {PTRW{1'b0}};
	reg [PTRW-1:0] rdptr = {PTRW{1'b0}};

	// wrptr synchronised into the rdclk domain (2 flops)
	reg [PTRW-1:0] wrptr_s1_rd = {PTRW{1'b0}};
	reg [PTRW-1:0] wrptr_s2_rd = {PTRW{1'b0}};

	// rdptr synchronised into the wrclk domain (2 flops)
	reg [PTRW-1:0] rdptr_s1_wr = {PTRW{1'b0}};
	reg [PTRW-1:0] rdptr_s2_wr = {PTRW{1'b0}};

	// ------------------------------------------------ write side (wrclk)
	wire             do_wr    = wrreq && !wrfull;
	wire [PTRW-1:0]  wrptr_nx = wrptr + {{(PTRW-1){1'b0}}, do_wr};
	wire [PTRW-1:0]  full_thr = {~rdptr_s2_wr[PTRW-1], rdptr_s2_wr[PTRW-2:0]};

	always @(posedge wrclk) begin
		if (aclr) begin
			wrptr       <= {PTRW{1'b0}};
			wrfull      <= 1'b0;
			rdptr_s1_wr <= {PTRW{1'b0}};
			rdptr_s2_wr <= {PTRW{1'b0}};
		end else begin
			rdptr_s1_wr <= rdptr;
			rdptr_s2_wr <= rdptr_s1_wr;
			if (do_wr) mem[wrptr[lpm_widthu-1:0]] <= data;
			wrptr  <= wrptr_nx;
			wrfull <= (wrptr_nx == full_thr);
		end
	end

	assign wrusedw = wrptr[PTRW-1:0] - rdptr_s2_wr;
	assign wrempty = (wrptr == rdptr_s2_wr);

	// ------------------------------------------------- read side (rdclk)
	wire            do_rd    = rdreq && !rdempty;
	wire [PTRW-1:0] rdptr_nx = rdptr + {{(PTRW-1){1'b0}}, do_rd};

	always @(posedge rdclk) begin
		if (aclr) begin
			rdptr       <= {PTRW{1'b0}};
			rdempty     <= 1'b1;
			wrptr_s1_rd <= {PTRW{1'b0}};
			wrptr_s2_rd <= {PTRW{1'b0}};
			q           <= {lpm_width{1'b0}};
		end else begin
			wrptr_s1_rd <= wrptr;
			wrptr_s2_rd <= wrptr_s1_rd;
			if (do_rd) q <= mem[rdptr[lpm_widthu-1:0]];
			rdptr   <= rdptr_nx;
			rdempty <= (rdptr_nx == wrptr_s2_rd);
		end
	end

	assign rdusedw = wrptr_s2_rd - rdptr;

	// Unused (left open by the instantiation).
	assign eccstatus = 1'b0;
	assign rdfull    = 1'b0;

endmodule
`default_nettype wire
