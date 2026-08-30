`timescale 1ns / 1ps

/**
 * Module: sogi_qsg
 * Description: Standalone Second-Order Generalized Integrator (SOGI) Quadrature 
 *              Signal Generator (QSG) with Frequency Adaptation (F-SOGI).
 *              Takes a single-phase scalar input signal and generates filtered 
 *              in-phase (u_alpha) and 90-degree phase-lagged (u_beta) outputs.
 */
module sogi_qsg #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,  // System clock frequency
    parameter real CENTER_FREQ_HZ = 60.0            // Target nominal grid frequency
) (
    input logic               clk,
    input logic               rst_n,
    input logic signed [15:0] u_in,   // Scalar input signal (e.g., v_out or i_out)
    input logic signed [15:0] k_sogi, // Gain factor (16'sd16384 = 1.0, Q1.14)

    output logic signed [15:0] u_alpha,  // In-phase filtered output
    output logic signed [15:0] u_beta    // Quadrature 90-degree lagged output
);

  // -------------------------------------------------------------------------
  // Local Parameters & Derived Math
  // -------------------------------------------------------------------------
  localparam real M_PI = 3.14159265358979323846;

  // Nominal Phase Increment: (CENTER_FREQ * 2^32) / CLOCK_FREQ
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;

  // Nominal SOGI Integration Step: 2 * M_PI * NOMINAL_PHASE_INC
  localparam real NOM_W0_DT_R = 2.0 * M_PI * NOM_PHASE_INC_R;
  localparam logic signed [31:0] NOMINAL_W0_DT = 32'($rtoi(NOM_W0_DT_R));

  // Scaled 2*PI factor: (2 * PI) * 2^16 = 411740.8
  localparam real W0_SCALE_R = (2.0 * M_PI) * 65536.0;
  localparam logic signed [63:0] W0_SCALE_FACTOR = 64'($rtoi(W0_SCALE_R));

  // Dynamic Clamping bounds (-15% to +15% frequency variation)
  localparam logic signed [31:0] W0_DT_MIN = 32'($rtoi(NOM_W0_DT_R * (5.1 / 6.0)));
  localparam logic signed [31:0] W0_DT_MAX = 32'($rtoi(NOM_W0_DT_R * (6.9 / 6.0)));

  // -------------------------------------------------------------------------
  // 1. Dynamic Frequency Adaptation (F-SOGI) - Ultra-Slow IIR Filter
  // -------------------------------------------------------------------------
  // Default to nominal phase increment assuming locked conditions
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  logic signed [31:0] w0_dt_dynamic;
  logic signed [47:0] w0_dt_iir_acc;
  logic signed [31:0] w0_dt_raw;
  logic signed [63:0] w0_mult_full;

  // Intermediate registered slice to fix Icarus bit-slicing warnings in always_comb
  logic signed [31:0] w0_dt_iir_msb;
  assign w0_dt_iir_msb = w0_dt_iir_acc[47:16];

  always_comb begin
    w0_mult_full = $signed({32'b0, NOMINAL_PHASE_INC}) * W0_SCALE_FACTOR;
    w0_dt_raw    = 32'(w0_mult_full >>> 16);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w0_dt_iir_acc <= 48'(NOMINAL_W0_DT) <<< 16;
    end else begin
      // Tau ~ 65.5k clocks (ultra-slow smooth frequency adaptation)
      w0_dt_iir_acc <= w0_dt_iir_acc + 48'($signed(w0_dt_raw) - $signed(w0_dt_iir_acc[47:16]));
    end
  end

  // Hard clamp w0_dt to prevent runaway loop dynamics
  always_comb begin
    if (w0_dt_iir_msb < W0_DT_MIN) w0_dt_dynamic = W0_DT_MIN;
    else if (w0_dt_iir_msb > W0_DT_MAX) w0_dt_dynamic = W0_DT_MAX;
    else w0_dt_dynamic = w0_dt_iir_msb;
  end

  // -------------------------------------------------------------------------
  // 2. Adaptive SOGI Core
  // -------------------------------------------------------------------------
  logic signed [47:0] alpha_acc;
  logic signed [47:0] beta_acc;

  logic signed [15:0] alpha_state;
  logic signed [15:0] beta_state;
  logic signed [31:0] err;
  logic signed [31:0] k_err;
  logic signed [31:0] d_alpha_raw;
  logic signed [31:0] d_beta_raw;

  logic signed [63:0] d_alpha_ext, d_beta_ext;
  logic signed [63:0] w0_dt_ext;

  assign alpha_state = alpha_acc[47:32];
  assign beta_state  = beta_acc[47:32];

  always_comb begin
    err         = $signed(u_in) - $signed(alpha_state);
    k_err       = ($signed(err) * $signed(k_sogi)) >>> 14;
    d_alpha_raw = k_err - $signed(beta_state);
    d_beta_raw  = $signed(alpha_state);

    d_alpha_ext = 64'(d_alpha_raw);
    d_beta_ext  = 64'(d_beta_raw);
    w0_dt_ext   = 64'(w0_dt_dynamic);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      alpha_acc <= '0;
      beta_acc  <= '0;
    end else begin
      alpha_acc <= alpha_acc + 48'(d_alpha_ext * w0_dt_ext);
      beta_acc  <= beta_acc + 48'(d_beta_ext * w0_dt_ext);
    end
  end

  assign u_alpha = alpha_state;
  assign u_beta  = beta_state;

endmodule
