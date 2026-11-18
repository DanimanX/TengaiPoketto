//
// psk_ddio_in16.sv
//
// 16-bit double-data-rate input register on the SDRAM data bus, with the same
// semantics as altera_mf's altddio_in:
//
//   q_h <= d sampled at each posedge clk
//   q_l <= d sampled at the PREVIOUS negedge clk
//
// On Cyclone V that is one DDIO input cell in the IOE: the two outputs are
// half a clock apart in sample time, which is what sdram.sv uses to move the
// read-data capture point by half a clk_sys cycle relative to the command
// edge (see the capture options documented in sdram.sv). Under Verilator the
// same behaviour is modelled directly, so the simulation sees exactly the
// half-cycle latency the hardware has.
//
module psk_ddio_in16 (
	input  wire        clk,
	input  wire [15:0] d,
	output wire [15:0] q_h,
	output wire [15:0] q_l
);

`ifdef VERILATOR

	reg [15:0] lat = 16'd0;
	reg [15:0] qh_r = 16'd0;
	reg [15:0] ql_r = 16'd0;

	always @(negedge clk) lat <= d;

	always @(posedge clk) begin
		qh_r <= d;
		ql_r <= lat;
	end

	assign q_h = qh_r;
	assign q_l = ql_r;

`else

	altddio_in #(
		.intended_device_family("Cyclone V"),
		.invert_input_clocks   ("OFF"),
		.lpm_hint              ("UNUSED"),
		.lpm_type              ("altddio_in"),
		.power_up_high         ("OFF"),
		.width                 (16)
	) u_altddio_in (
		.datain    (d),
		.inclock   (clk),
		.dataout_h (q_h),
		.dataout_l (q_l),
		.aclr      (1'b0),
		.aset      (1'b0),
		.inclocken (1'b1),
		.sclr      (1'b0),
		.sset      (1'b0)
	);

`endif

endmodule

