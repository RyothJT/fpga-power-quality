`timescale 1ns / 1ps

/**
 * Module: sogi_qsg
 * Description: Second-Order Generalized Integrator (SOGI) Quadrature Signal Generator (QSG)
 *              with Optional Parameter-Controlled Dynamic Frequency Adaptation.
 */
module sogi_qsg #(
    parameter real  CLOCK_FREQ_HZ    = 100_000_000.0, // System clock frequency
    parameter real  CENTER_FREQ_HZ   = 60.0,          // Target nominal grid frequency
    parameter bit   ENABLE_FREQ_ADAPT = 1'b1           // 1: Enable PLL feedback adaptation, 0: Fixed nominal freq
) (
    input logic               clk,
    input logic               rst_n,
    input logic signed [15:0] u_in,          // Scalar input signal
    input logic signed [15:0] k_sogi,        // Gain factor (16'sd16384 = 1.0, Q1.14)
    input logic        [31:0] phase_inc_in,  // Dynamic phase increment (used when ENABLE_FREQ_ADAPT = 1)

    output logic signed [15:0] u_alpha,      // In-phase filtered output
    output logic signed [15:0] u_beta        // Quadrature 90-degree lagged output
);

  // -------------------------------------------------------------------------
  // Local Parameters & Derived Math
  // -------------------------------------------------------------------------
  localparam real M_PI = 3.14159265358979323846;

  // Nominal Phase Increment: (CENTER_FREQ * 2^32) / CLOCK_FREQ
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  // Scaled 2*PI factor: (2 * PI) * 2^16
  localparam real W0_SCALE_R = (2.0 * M_PI) * 65536.0;
  localparam logic signed [63:0] W0_SCALE_FACTOR = 64'($rtoi(W0_SCALE_R));

  // Fixed Nominal w0_dt value (pre-calculated at compile time for open-loop mode)
  localparam logic signed [63:0] FIXED_W0_MULT = $signed({32'b0, NOMINAL_PHASE_INC}) * W0_SCALE_FACTOR;
  localparam logic signed [31:0] FIXED_W0_DT   = 32'(FIXED_W0_MULT >>> 16);

  // Dynamic Clamping bounds (-20% to +20% frequency variation: e.g., 48Hz - 72Hz)
  localparam real NOM_W0_DT_R = 2.0 * M_PI * NOM_PHASE_INC_R;
  localparam logic signed [31:0] W0_DT_MIN = 32'($rtoi(NOM_W0_DT_R * 0.80));
  localparam logic signed [31:0] W0_DT_MAX = 32'($rtoi(NOM_W0_DT_R * 1.20));

  // -------------------------------------------------------------------------
  // Dynamic Clock-Independent Damping Constant Calculation
  // Target time constant tau = 1.0 ms (f_cutoff ~ 160 Hz for parameter smoothing)
  // -------------------------------------------------------------------------
  localparam real TARGET_TAU_SEC = 0.001;
  localparam real SHIFT_CALC = $ln(CLOCK_FREQ_HZ * TARGET_TAU_SEC) / $ln(2.0);

  localparam int SHIFT_BITS = (SHIFT_CALC < 2.0) ? 2 : ((SHIFT_CALC > 16.0) ? 16 : $rtoi(
      SHIFT_CALC
  ));

  // -------------------------------------------------------------------------
  // 1. Parameter-Controlled Frequency Adaptation Core
  // -------------------------------------------------------------------------
  logic signed [31:0] w0_dt_dynamic;

  generate
    if (ENABLE_FREQ_ADAPT) begin : g_freq_adapt
      logic signed [47:0] w0_dt_iir_acc;
      logic signed [31:0] w0_dt_raw;
      logic signed [63:0] w0_mult_full;

      logic signed [31:0] w0_dt_iir_msb;
      assign w0_dt_iir_msb = w0_dt_iir_acc[47:16];

      // Dynamic frequency math driven by phase_inc_in input
      assign w0_mult_full = $signed({32'b0, phase_inc_in}) * W0_SCALE_FACTOR;
      assign w0_dt_raw    = 32'(w0_mult_full >>> 16);

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          w0_dt_iir_acc <= {FIXED_W0_DT, 16'b0};
        end else begin
          w0_dt_iir_acc <= w0_dt_iir_acc - (w0_dt_iir_acc >>> SHIFT_BITS) + ({w0_dt_raw, 16'b0} >>> SHIFT_BITS);
        end
      end

      // Dynamic clamping bounds
      always_comb begin
        if (w0_dt_iir_msb < W0_DT_MIN) begin
          w0_dt_dynamic = W0_DT_MIN;
        end else if (w0_dt_iir_msb > W0_DT_MAX) begin
          w0_dt_dynamic = W0_DT_MAX;
        end else begin
          w0_dt_dynamic = w0_dt_iir_msb;
        end
      end

    end else begin : g_fixed_freq
      // Standalone mode: Fixed compile-time nominal center frequency (zero runtime hardware overhead)
      assign w0_dt_dynamic = FIXED_W0_DT;
    end
  endgenerate

  // -------------------------------------------------------------------------
  // 2. SOGI Core Integrators
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

// Inside sogi_qsg.sv

  logic signed [47:0] next_alpha_acc, next_beta_acc;
  localparam logic signed [47:0] POS_LIMIT = 48'h7FFF_FFFF_FFFF;
  localparam logic signed [47:0] NEG_LIMIT = 48'h8000_0000_0000;

  always_comb begin
    // Calculate the next raw states
    next_alpha_acc = alpha_acc + 48'($signed(d_alpha_ext * w0_dt_ext));
    next_beta_acc  = beta_acc  + 48'($signed(d_beta_ext * w0_dt_ext));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      alpha_acc <= '0;
      beta_acc  <= '0;
    end else begin
      // Apply Saturation to Alpha Integrator
      if (($signed(alpha_acc) > 0) && ($signed(d_alpha_ext * w0_dt_ext) > 0) && (next_alpha_acc < 0)) begin
          alpha_acc <= POS_LIMIT; // Positive Overflow
      end else if (($signed(alpha_acc) < 0) && ($signed(d_alpha_ext * w0_dt_ext) < 0) && (next_alpha_acc >= 0)) begin
          alpha_acc <= NEG_LIMIT; // Negative Overflow
      end else begin
          alpha_acc <= next_alpha_acc;
      end

      // Apply Saturation to Beta Integrator
      if (($signed(beta_acc) > 0) && ($signed(d_beta_ext * w0_dt_ext) > 0) && (next_beta_acc < 0)) begin
          beta_acc <= POS_LIMIT; // Positive Overflow
      end else if (($signed(beta_acc) < 0) && ($signed(d_beta_ext * w0_dt_ext) < 0) && (next_beta_acc >= 0)) begin
          beta_acc <= NEG_LIMIT; // Negative Overflow
      end else begin
          beta_acc <= next_beta_acc;
      end
    end
  end

  assign u_alpha = alpha_state;
  assign u_beta  = beta_state;

  // Synthesis linting cleanup (ignore unused input when adaptation disabled)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] unused_phase_inc;
  assign unused_phase_inc = phase_inc_in;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
