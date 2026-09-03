`timescale 1ns / 1ps

module power_engine #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0,
    parameter real CUTOFF_FREQ_HZ = 5.0
) (
    input logic clk,
    input logic rst_n,

    input logic signed [15:0] v_alpha,
    v_beta,
    input logic signed [15:0] i_alpha,
    i_beta,

    output logic signed [15:0] p_inst,
    q_inst,
    output logic signed [15:0] p_avg,
    q_avg,
    output logic        [15:0] v_rms,
    i_rms
);

  localparam real DIVISOR = CLOCK_FREQ_HZ / (2.0 * 3.1415926535 * CUTOFF_FREQ_HZ);
  localparam int K = $clog2($rtoi(DIVISOR));

  // -------------------------------------------------------------------------
  // 1. Instantaneous Power Pipeline (P and Q)
  // -------------------------------------------------------------------------
  logic signed [15:0] va_reg, vb_reg, ia_reg, ib_reg;
  logic signed [31:0] p_proda_m, p_prodb_m, q_proda_m, q_prodb_m;
  logic signed [31:0] p_proda_p, p_prodb_p, q_proda_p, q_prodb_p;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {va_reg, vb_reg, ia_reg, ib_reg} <= '0;
      {p_proda_m, p_prodb_m, q_proda_m, q_prodb_m} <= '0;
      {p_proda_p, p_prodb_p, q_proda_p, q_prodb_p} <= '0;
      p_inst <= '0;
      q_inst <= '0;
    end else begin
      // Stage 1: Input AREG/BREG
      va_reg <= v_alpha;
      vb_reg <= v_beta;
      ia_reg <= i_alpha;
      ib_reg <= i_beta;

      // Stage 2: MREG
      p_proda_m <= va_reg * ia_reg;
      p_prodb_m <= vb_reg * ib_reg;
      q_proda_m <= vb_reg * ia_reg;
      q_prodb_m <= va_reg * ib_reg;

      // Stage 3: PREG
      p_proda_p <= p_proda_m;
      p_prodb_p <= p_prodb_m;
      q_proda_p <= q_proda_m;
      q_prodb_p <= q_prodb_m;

      // Stage 4: Sum and Shift (Q30 -> Q15 and divide by 2)
      p_inst <= 16'(($signed(p_proda_p) + $signed(p_prodb_p)) >>> 16);
      q_inst <= 16'(($signed(q_proda_p) - $signed(q_prodb_p)) >>> 16);
    end
  end

  // -------------------------------------------------------------------------
  // 2. Mean Power IIR Filters
  // -------------------------------------------------------------------------
  logic signed [16+K-1:0] p_iir_acc, q_iir_acc;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_iir_acc <= '0;
      q_iir_acc <= '0;
    end else begin
      p_iir_acc <= p_iir_acc + $signed(p_inst) - $signed(p_iir_acc >>> K);
      q_iir_acc <= q_iir_acc + $signed(q_inst) - $signed(q_iir_acc >>> K);
    end
  end
  assign p_avg = 16'($signed(p_iir_acc + (1 << (K - 1))) >>> K);
  assign q_avg = 16'($signed(q_iir_acc + (1 << (K - 1))) >>> K);

  // -------------------------------------------------------------------------
  // 3. RMS Squaring Pipeline (v^2 and i^2)
  // -------------------------------------------------------------------------
  // Note: Squaring a 16-bit signed results in 31-bit unsigned. We use 32-bit logic.
  logic [31:0] va_sq_m, vb_sq_m, ia_sq_m, ib_sq_m;
  logic [31:0] va_sq_p, vb_sq_p, ia_sq_p, ib_sq_p;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {va_sq_m, vb_sq_m, ia_sq_m, ib_sq_m} <= '0;
      {va_sq_p, vb_sq_p, ia_sq_p, ib_sq_p} <= '0;
    end else begin
      // Stage 2: MREG (Inputs are already registered in va_reg etc. from Section 1)
      va_sq_m <= va_reg * va_reg;
      vb_sq_m <= vb_reg * vb_reg;
      ia_sq_m <= ia_reg * ia_reg;
      ib_sq_m <= ib_reg * ib_reg;

      // Stage 3: PREG
      va_sq_p <= va_sq_m;
      vb_sq_p <= vb_sq_m;
      ia_sq_p <= ia_sq_m;
      ib_sq_p <= ib_sq_m;
    end
  end

  // Stage 4: Mean Square calculation ( (a^2 + b^2) / 2 )
  logic [31:0] v_mag_sq, i_mag_sq;
  assign v_mag_sq = (va_sq_p + vb_sq_p) >> 1;
  assign i_mag_sq = (ia_sq_p + ib_sq_p) >> 1;

  // -------------------------------------------------------------------------
  // 4. RMS IIR Accumulators and Square Root
  // -------------------------------------------------------------------------
  logic [32+K-1:0] v_sq_acc, i_sq_acc;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_sq_acc <= '0;
      i_sq_acc <= '0;
    end else begin
      v_sq_acc <= v_sq_acc + v_mag_sq - (v_sq_acc >> K);
      i_sq_acc <= i_sq_acc + i_mag_sq - (i_sq_acc >> K);
    end
  end

  wire [31:0] v_ms = (v_sq_acc + (1 << (K - 1))) >> K;
  wire [31:0] i_ms = (i_sq_acc + (1 << (K - 1))) >> K;

  isqrt #(
      .WIDTH(32)
  ) u_isqrt_v (
      .clk(clk),
      .rst_n(rst_n),
      .val_in(v_ms),
      .root_out(v_rms)
  );
  isqrt #(
      .WIDTH(32)
  ) u_isqrt_i (
      .clk(clk),
      .rst_n(rst_n),
      .val_in(i_ms),
      .root_out(i_rms)
  );

endmodule
