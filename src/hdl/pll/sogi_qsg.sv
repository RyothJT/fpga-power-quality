`timescale 1ns / 1ps

/**
 * Module: sogi_qsg
 * Description: Second-Order Generalized Integrator (SOGI) Quadrature Signal Generator (QSG)
 *              with Fully Registered DSP Blocks and Isolate Dynamic Frequency Clamping.
 */
module sogi_qsg #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,  // System clock frequency
    parameter real CENTER_FREQ_HZ = 60.0,  // Target nominal grid frequency
    parameter bit  ENABLE_FREQ_ADAPT = 1'b1          // 1: Enable PLL feedback adaptation, 0: Fixed nominal freq
) (
    input logic signed [15:0] u_in,  // Scalar input signal
    input logic signed [15:0] k_sogi,  // Gain factor (16'sd16384 = 1.0, Q1.14)
    input logic [31:0] phase_inc_in,  // Dynamic phase increment (used when ENABLE_FREQ_ADAPT = 1)
    input logic clk,
    input logic rst_n,

    output logic signed [15:0] u_alpha,  // In-phase filtered output
    output logic signed [15:0] u_beta    // Quadrature 90-degree lagged output
);

  // -------------------------------------------------------------------------
  // Local Parameters & Compile-Time Math
  // -------------------------------------------------------------------------
  localparam real M_PI = 3.14159265358979323846;

  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  localparam real W0_SCALE_R = (2.0 * M_PI) * 65536.0;
  localparam logic signed [63:0] W0_SCALE_FACTOR = 64'($rtoi(W0_SCALE_R));

  localparam logic signed [63:0] FIXED_W0_MULT = $signed(
      {32'b0, NOMINAL_PHASE_INC}
  ) * W0_SCALE_FACTOR;
  localparam logic signed [31:0] FIXED_W0_DT = 32'(FIXED_W0_MULT >>> 16);

  localparam real NOM_W0_DT_R = 2.0 * M_PI * NOM_PHASE_INC_R;
  localparam logic signed [31:0] W0_DT_MIN = 32'($rtoi(NOM_W0_DT_R * 0.80));
  localparam logic signed [31:0] W0_DT_MAX = 32'($rtoi(NOM_W0_DT_R * 1.20));

  localparam real TARGET_TAU_SEC = 0.0001;
  localparam real SHIFT_CALC = $ln(CLOCK_FREQ_HZ * TARGET_TAU_SEC) / $ln(2.0);
  localparam int SHIFT_BITS = (SHIFT_CALC < 2.0) ? 2 : ((SHIFT_CALC > 16.0) ? 16 : $rtoi(
      SHIFT_CALC
  ));

  localparam logic signed [47:0] POS_LIMIT = 48'h7FFF_FFFF_FFFF;
  localparam logic signed [47:0] NEG_LIMIT = 48'h8000_0000_0000;

  // -------------------------------------------------------------------------
  // 1. Parameter-Controlled Frequency Adaptation Core (Fully Registered)
  // -------------------------------------------------------------------------
  (* keep = "true" *) logic signed [31:0] w0_dt_dynamic;

  generate
    if (ENABLE_FREQ_ADAPT) begin : g_freq_adapt
      logic signed [47:0] w0_dt_iir_acc;
      logic signed [31:0] w0_dt_raw;

      (* use_dsp = "yes" *)logic signed [63:0] w0_mult_full_reg;

      logic signed [31:0] w0_dt_iir_msb;
      assign w0_dt_iir_msb = w0_dt_iir_acc[47:16];

      // Stage F1: Input Multiplication
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          w0_mult_full_reg <= '0;
          w0_dt_raw        <= FIXED_W0_DT;
        end else begin
          w0_mult_full_reg <= $signed({32'b0, phase_inc_in}) * W0_SCALE_FACTOR;
          w0_dt_raw        <= 32'(w0_mult_full_reg >>> 16);
        end
      end

      // Stage F2: IIR Smoothing Filter Accumulation
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          w0_dt_iir_acc <= {FIXED_W0_DT, 16'b0};
        end else begin
          w0_dt_iir_acc <= w0_dt_iir_acc - (w0_dt_iir_acc >>> SHIFT_BITS) + ({w0_dt_raw, 16'b0} >>> SHIFT_BITS);
        end
      end

      // Stage F3: Clamping Output Pipeline Register (FIXES PATH SECTION 1)
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          w0_dt_dynamic <= FIXED_W0_DT;
        end else begin
          if (w0_dt_iir_msb < W0_DT_MIN) begin
            w0_dt_dynamic <= W0_DT_MIN;
          end else if (w0_dt_iir_msb > W0_DT_MAX) begin
            w0_dt_dynamic <= W0_DT_MAX;
          end else begin
            w0_dt_dynamic <= w0_dt_iir_msb;
          end
        end
      end

    end else begin : g_fixed_freq
      assign w0_dt_dynamic = FIXED_W0_DT;
    end
  endgenerate

  // -------------------------------------------------------------------------
  // 2. Multi-Stage Pipelined SOGI Integrator Loop
  // -------------------------------------------------------------------------
  logic signed [47:0] alpha_acc, beta_acc;
  logic signed [15:0] alpha_state, beta_state;

  assign alpha_state = alpha_acc[47:32];
  assign beta_state  = beta_acc[47:32];

  // Pipeline Signals
  // --- STAGE 1: Error & Gain Math ---
  (* use_dsp = "yes" *)logic signed [31:0] stg1_k_err;
  logic signed [15:0] stg1_alpha_state;
  logic signed [15:0] stg1_beta_state;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stg1_k_err       <= '0;
      stg1_alpha_state <= '0;
      stg1_beta_state  <= '0;
    end else begin
      stg1_k_err       <= ($signed($signed(u_in) - $signed(alpha_state)) * $signed(k_sogi)) >>> 14;
      stg1_alpha_state <= alpha_state;
      stg1_beta_state  <= beta_state;
    end
  end

  // --- STAGE 2: Derivative Calculation & Registered Multipliers ---
  // Intermediate registered derivative terms to cleanly infer DSP MREG
  logic signed [31:0] stg2_d_alpha_reg, stg2_d_beta_reg;
  logic signed [31:0] stg2_w0_dt_reg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stg2_d_alpha_reg <= '0;
      stg2_d_beta_reg  <= '0;
      stg2_w0_dt_reg   <= '0;
    end else begin
      stg2_d_alpha_reg <= stg1_k_err - $signed(stg1_beta_state);
      stg2_d_beta_reg  <= $signed(stg1_alpha_state);
      stg2_w0_dt_reg   <= w0_dt_dynamic;
    end
  end

  // --- STAGE 3: DSP Multiplication Output Registers (FIXES PATH SECTION 2 & 3) ---
  (* use_dsp = "yes" *)logic signed [63:0] stg3_prod_alpha;
  (* use_dsp = "yes" *)logic signed [63:0] stg3_prod_beta;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stg3_prod_alpha <= '0;
      stg3_prod_beta  <= '0;
    end else begin
      stg3_prod_alpha <= 64'(stg2_d_alpha_reg) * 64'(stg2_w0_dt_reg);
      stg3_prod_beta  <= 64'(stg2_d_beta_reg) * 64'(stg2_w0_dt_reg);
    end
  end

  // --- STAGE 4: Accumulation and Saturation ---
  logic signed [47:0] next_alpha_acc, next_beta_acc;

  assign next_alpha_acc = alpha_acc + 48'(stg3_prod_alpha);
  assign next_beta_acc  = beta_acc + 48'(stg3_prod_beta);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      alpha_acc <= '0;
      beta_acc  <= '0;
    end else begin
      // Saturation for Alpha Integrator
      if (($signed(alpha_acc) > 0) && ($signed(stg3_prod_alpha) > 0) && (next_alpha_acc < 0)) begin
        alpha_acc <= POS_LIMIT;
      end else if (($signed(
              alpha_acc
          ) < 0) && ($signed(
              stg3_prod_alpha
          ) < 0) && (next_alpha_acc >= 0)) begin
        alpha_acc <= NEG_LIMIT;
      end else begin
        alpha_acc <= next_alpha_acc;
      end

      // Saturation for Beta Integrator
      if (($signed(beta_acc) > 0) && ($signed(stg3_prod_beta) > 0) && (next_beta_acc < 0)) begin
        beta_acc <= POS_LIMIT;
      end else if (($signed(
              beta_acc
          ) < 0) && ($signed(
              stg3_prod_beta
          ) < 0) && (next_beta_acc >= 0)) begin
        beta_acc <= NEG_LIMIT;
      end else begin
        beta_acc <= next_beta_acc;
      end
    end
  end

  // Output Assignments
  assign u_alpha = alpha_state;
  assign u_beta  = beta_state;

  // Linting cleanup for unused parameters
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] unused_phase_inc;
  assign unused_phase_inc = phase_inc_in;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
