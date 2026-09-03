`timescale 1ns / 1ps

module sogi_qsg #(
    parameter real  CLOCK_FREQ_HZ    = 100_000_000.0,
    parameter real  CENTER_FREQ_HZ   = 60.0,
    parameter bit   ENABLE_FREQ_ADAPT = 1'b1
) (
    input logic               clk,
    input logic               rst_n,
    input logic signed [15:0] u_in,
    input logic signed [15:0] k_sogi,
    input logic        [31:0] phase_inc_in,

    output logic signed [15:0] u_alpha,
    output logic signed [15:0] u_beta
);

  // -------------------------------------------------------------------------
  // 1. Frequency Adaptation (Strict DSP Pipeline)
  // -------------------------------------------------------------------------
  localparam real M_PI = 3.14159265358979323846;
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;
  localparam logic signed [31:0] FIXED_W0_DT = 32'($rtoi(2.0 * M_PI * NOM_PHASE_INC_R));

  logic signed [31:0] w0_dt_dynamic;

  generate
    if (ENABLE_FREQ_ADAPT) begin : g_freq_adapt
      localparam logic signed [17:0] W0_FACTOR_SMALL = 18'($rtoi(2.0 * M_PI * 8192.0));
      logic signed [31:0] p_inc_pipe1, p_inc_pipe2;
      logic signed [49:0] w0_mreg, w0_preg;
      logic signed [31:0] w0_dt_raw;
      logic signed [47:0] w0_dt_iir_acc;

      always_ff @(posedge clk) begin
        // Multiplier Pipeline (NO RESET)
        p_inc_pipe1 <= $signed({1'b0, phase_inc_in});
        p_inc_pipe2 <= p_inc_pipe1;  // AREG=2
        w0_mreg     <= p_inc_pipe2 * W0_FACTOR_SMALL;  // MREG
        w0_preg     <= w0_mreg;  // PREG

        if (!rst_n) begin
          w0_dt_iir_acc <= {FIXED_W0_DT, 16'b0};
          w0_dt_raw     <= FIXED_W0_DT;
        end else begin
          w0_dt_raw     <= 32'(w0_preg >>> 13);
          w0_dt_iir_acc <= w0_dt_iir_acc - (w0_dt_iir_acc >>> 16) + ({w0_dt_raw, 16'b0} >>> 16);
        end
      end
      assign w0_dt_dynamic = w0_dt_iir_acc[47:16];
    end else begin : g_fixed_freq
      assign w0_dt_dynamic = FIXED_W0_DT;
    end
  endgenerate

  // -------------------------------------------------------------------------
  // 2. SOGI Core Integrators (Strict 10-Stage Hardware Pipeline)
  // -------------------------------------------------------------------------
  logic signed [47:0] alpha_acc, beta_acc;
  logic signed [15:0] alpha_state, beta_state;
  assign alpha_state = alpha_acc[47:32];
  assign beta_state  = beta_acc[47:32];

  // --- FABRIC STAGE (Logic with Resets) ---
  logic signed [15:0] err_logic;
  logic signed [31:0] d_alpha_logic, d_beta_logic;
  logic signed [31:0] w0_logic;

  // --- DSP STAGE 1: Multiplier 1 (k * err) ---
  // NO RESET ALLOWED. Pure data pipeline for MREG/PREG inference.
  (* use_dsp = "yes" *) logic signed [15:0] m1_a, m1_b;
  (* use_dsp = "yes" *) logic signed [31:0] m1_mreg, m1_preg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      err_logic     <= '0;
      d_alpha_logic <= '0;
      d_beta_logic  <= '0;
      w0_logic      <= FIXED_W0_DT;
    end else begin
      err_logic     <= u_in - alpha_state;
      d_alpha_logic <= (m1_preg >>> 14) - $signed(beta_state);
      d_beta_logic  <= $signed(alpha_state);
      w0_logic      <= w0_dt_dynamic;
    end
  end

  always_ff @(posedge clk) begin
    m1_a    <= err_logic;
    m1_b    <= k_sogi;
    m1_mreg <= m1_a * m1_b; // Hardware MREG
    m1_preg <= m1_mreg;     // Hardware PREG
  end

  // --- DSP STAGE 2: Multipliers 2 & 3 (d * w0) ---
  // 32x32 multiply: Needs 2 stages of input regs for cascade (AREG/BREG)
  (* use_dsp = "yes" *) logic signed [31:0] m2_a_pipe1, m2_a_pipe2, m2_b_pipe1, m2_b_pipe2;
  (* use_dsp = "yes" *) logic signed [31:0] m3_a_pipe1, m3_a_pipe2, m3_b_pipe1, m3_b_pipe2;
  (* use_dsp = "yes" *) logic signed [63:0] m2_mreg, m2_preg, m3_mreg, m3_preg;

  always_ff @(posedge clk) begin
    // Stage 1: AREG1/BREG1
    m2_a_pipe1 <= d_alpha_logic;
    m2_b_pipe1 <= w0_logic;
    m3_a_pipe1 <= d_beta_logic;
    m3_b_pipe1 <= w0_logic;

    // Stage 2: AREG2/BREG2
    m2_a_pipe2 <= m2_a_pipe1;
    m2_b_pipe2 <= m2_b_pipe1;
    m3_a_pipe2 <= m3_a_pipe1;
    m3_b_pipe2 <= m3_b_pipe1;

    // Stage 3: MREG
    m2_mreg    <= m2_a_pipe2 * m2_b_pipe2;
    m3_mreg    <= m3_a_pipe2 * m3_b_pipe2;

    // Stage 4: PREG
    m2_preg    <= m2_mreg;
    m3_preg    <= m3_mreg;
  end

  // --- INTEGRATOR STAGE (Reset Required) ---
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      alpha_acc <= '0;
      beta_acc  <= '0;
    end else begin
      alpha_acc <= alpha_acc + 48'(m2_preg);
      beta_acc  <= beta_acc + 48'(m3_preg);
    end
  end

  assign u_alpha = alpha_acc[47:32];
  assign u_beta  = beta_acc[47:32];

endmodule
