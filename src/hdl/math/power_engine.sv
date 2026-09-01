`timescale 1ns / 1ps

module power_engine #(
    parameter real CLOCK_FREQ_HZ  = 1_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0,
    parameter real CUTOFF_FREQ_HZ = 5.0
) (
    input logic clk,
    input logic rst_n,

    input logic signed [15:0] v_alpha,
    input logic signed [15:0] v_beta,
    input logic signed [15:0] i_alpha,
    input logic signed [15:0] i_beta,

    output logic signed [15:0] p_inst,
    output logic signed [15:0] q_inst,
    output logic signed [15:0] p_avg,
    output logic signed [15:0] q_avg,
    output logic        [15:0] v_rms,
    output logic        [15:0] i_rms
);

  // Derive bit-shift factor K dynamically from clock frequency and target cutoff
  localparam real DIVISOR = CLOCK_FREQ_HZ / (2.0 * 3.141592653589793 * CUTOFF_FREQ_HZ);
  localparam int K = $clog2($rtoi(DIVISOR));

  // -------------------------------------------------------------------------
  // 1. Instantaneous Power Multiplications
  // -------------------------------------------------------------------------
  logic signed [31:0] p_prod_a, p_prod_b;
  logic signed [31:0] q_prod_a, q_prod_b;
  logic signed [31:0] q_mult_a, q_mult_b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_prod_a <= '0;
      p_prod_b <= '0;
      q_prod_a <= '0;
      q_prod_b <= '0;
      p_inst   <= '0;
      q_inst   <= '0;
    end else begin
      p_prod_a <= $signed(v_alpha) * $signed(i_alpha);
      p_prod_b <= $signed(v_beta) * $signed(i_beta);

      q_prod_a <= $signed(v_beta) * $signed(i_alpha);
      q_prod_b <= $signed(v_alpha) * $signed(i_beta);

      p_inst   <= 16'(($signed(p_prod_a) + $signed(p_prod_b)) >>> 16);
      q_inst   <= 16'(($signed(q_prod_a) - $signed(q_prod_b)) >>> 16);
    end
  end

  // -------------------------------------------------------------------------
  // 2. Mean Active and Reactive Power Filtering (with Unbiased Rounding)
  // -------------------------------------------------------------------------
  logic signed [16+K-1:0] p_iir_acc;
  logic signed [16+K-1:0] q_iir_acc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_iir_acc <= '0;
      q_iir_acc <= '0;
    end else begin
      p_iir_acc <= p_iir_acc + $signed(p_inst) - $signed(p_iir_acc >>> K);
      q_iir_acc <= q_iir_acc + $signed(q_inst) - $signed(q_iir_acc >>> K);
    end
  end

  // Round to nearest integer using 2^(K-1) rounding constant
  assign p_avg = 16'($signed(p_iir_acc + (1 << (K - 1))) >>> K);
  assign q_avg = 16'($signed(q_iir_acc + (1 << (K - 1))) >>> K);
  // -------------------------------------------------------------------------
  // 3. Squared Signal & Mean Square Accumulation
  // -------------------------------------------------------------------------
  logic [31:0] v_mag_sq, i_mag_sq;

  // v_alpha^2 + v_beta^2 = Peak Amplitude Squared.
  // We divide by 2 to get the Mean Square (MS) for a sine wave.
  // Using 33 bits for the sum to prevent overflow before the shift
  assign v_mag_sq = 32'((($signed(
      v_alpha
  ) * $signed(
      v_alpha
  )) + ($signed(
      v_beta
  ) * $signed(
      v_beta
  ))) >>> 1);

  assign i_mag_sq = 32'((($signed(
      i_alpha
  ) * $signed(
      i_alpha
  )) + ($signed(
      i_beta
  ) * $signed(
      i_beta
  ))) >>> 1);

  // Accumulators must be wide enough to hold 32 bits + K bits of filtering state
  logic [32+K-1:0] v_sq_acc, i_sq_acc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_sq_acc <= '0;
      i_sq_acc <= '0;
    end else begin
      // Standard IIR Filter: acc = acc + input - (acc >> K)
      // No pre-shifting! Keep the full precision of the 32-bit square.
      v_sq_acc <= v_sq_acc + v_mag_sq - (v_sq_acc >> K);
      i_sq_acc <= i_sq_acc + i_mag_sq - (i_sq_acc >> K);
    end
  end

  // Extract the filtered Mean Square (MS) value
  wire [31:0] v_ms = (v_sq_acc + (1 << (K - 1))) >> K;
  wire [31:0] i_ms = (i_sq_acc + (1 << (K - 1))) >> K;

  // -------------------------------------------------------------------------
  // 4. Square Root Core
  // -------------------------------------------------------------------------
  // Input: 32-bit (Mean Square), Output: 16-bit (Root Mean Square)
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
