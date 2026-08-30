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
  logic signed [31:0] p_mult_raw;
  logic signed [31:0] q_mult_a, q_mult_b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_mult_raw <= '0;
      q_mult_a   <= '0;
      q_mult_b   <= '0;
      p_inst     <= '0;
      q_inst     <= '0;
    end else begin
      p_mult_raw <= $signed(v_alpha) * $signed(i_alpha);
      q_mult_a   <= $signed(v_beta) * $signed(i_alpha);
      q_mult_b   <= $signed(v_alpha) * $signed(i_beta);

      p_inst     <= 16'(p_mult_raw >>> 15);
      q_inst     <= 16'(($signed(q_mult_a) - $signed(q_mult_b)) >>> 15);
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
  // 3. Squared Signal & Mean Square Accumulation (with Unbiased Rounding)
  // -------------------------------------------------------------------------
  logic signed [31:0] v_sq, i_sq;
  logic [16+K-1:0] v_sq_acc, i_sq_acc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_sq     <= '0;
      i_sq     <= '0;
      v_sq_acc <= '0;
      i_sq_acc <= '0;
    end else begin
      v_sq <= $signed(v_alpha) * $signed(v_alpha);
      i_sq <= $signed(i_alpha) * $signed(i_alpha);

      v_sq_acc <= v_sq_acc + 16'(v_sq >> 16) - (v_sq_acc >> K);
      i_sq_acc <= i_sq_acc + 16'(i_sq >> 16) - (i_sq_acc >> K);
    end
  end

  // -------------------------------------------------------------------------
  // 4. Square Root Core
  // -------------------------------------------------------------------------
  function automatic logic [15:0] isqrt(input logic [31:0] val);
    logic [31:0] a;
    logic [15:0] q;
    logic [33:0] right, r;
    begin
      a = val;
      q = 0;
      r = 0;
      for (int i = 0; i < 16; i++) begin
        r     = {r[31:0], a[31:30]};
        a     = a << 2;
        right = {q, 2'b01};
        if (r >= right) begin
          r = r - right;
          q = {q[14:0], 1'b1};
        end else begin
          q = {q[14:0], 1'b0};
        end
      end
      return q;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_rms <= '0;
      i_rms <= '0;
    end else begin
      v_rms <= isqrt({16'((v_sq_acc + (1 << (K - 1))) >> K), 16'b0});
      i_rms <= isqrt({16'((i_sq_acc + (1 << (K - 1))) >> K), 16'b0});
    end
  end

endmodule
