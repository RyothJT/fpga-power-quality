`timescale 1ns / 1ps

module system_top #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,
    parameter real SAMPLE_RATE_HZ = 20_000.0,
    parameter real CENTER_FREQ_HZ = 60.0
) (
    input logic clk,
    input logic rst_n,

    // Input Samples (From DDS in HIL, or XADC in Hardware)
    input logic signed [15:0] v_in,
    input logic signed [15:0] i_in,
    input logic               measure_en, // Strobe for calculation timing

    // SOGI Control Gains
    input logic signed [15:0] k_sogi,
    input logic signed [15:0] kp_pll,
    input logic signed [15:0] ki_pll,

    // Processing Outputs
    output logic signed [ 15:0] v_alpha,
    v_beta,
    output logic signed [ 15:0] v_d,
    v_q,
    output logic        [ 15:0] theta,
    output logic        [15:-8] freq_out,
    output logic                pll_locked,
    output logic signed [ 15:0] i_alpha,
    i_beta,
    output logic signed [ 15:0] p_inst,
    q_inst,
    output logic signed [ 15:0] p_avg,
    q_avg,
    output logic        [ 15:0] v_rms,
    i_rms,
    output logic        [3:-12] thd_val,
    thd_12c,

    // UART for diagnostics
    output logic uart_busy,
    output logic uart_tx_out
);

  wire uart_update_strobe;

  // 1. Diagnostic Transmitter
  diagnostic_transmitter u_diag (
      .clk          (clk),
      .rst          (~rst_n),
      .update_strobe(uart_update_strobe),
      .force_strobe (1'b0),
      .v_rms        (v_rms),
      .i_rms        (i_rms),
      .p_avg        (p_avg),
      .q_avg        (q_avg),
      .v_q          (v_q),
      .freq         (freq_out[7:-8]),
      .thd_12c      (thd_12c),
      .locked       (pll_locked),
      .RsTx         (uart_tx_out),
      .busy         (uart_busy)
  );

  // 2. Grid Frontend (SOGI-PLL & Vectorization)
  grid_frontend #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_frontend (
      .clk       (clk),
      .rst_n     (rst_n),
      .v_in      (v_in),
      .i_in      (i_in),
      .k_sogi    (k_sogi),
      .kp_pll    (kp_pll),
      .ki_pll    (ki_pll),
      .v_alpha   (v_alpha),
      .v_beta    (v_beta),
      .i_alpha   (i_alpha),
      .i_beta    (i_beta),
      .v_d       (v_d),
      .v_q       (v_q),
      .theta     (theta),
      .freq_out  (freq_out),
      .pll_locked(pll_locked)
  );

  // 3. Power & RMS Metrics Engine
  power_engine #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_power (
      .clk    (clk),
      .rst_n  (rst_n),
      .v_alpha(v_alpha),
      .v_beta (v_beta),
      .i_alpha(i_alpha),
      .i_beta (i_beta),
      .p_inst (p_inst),
      .q_inst (q_inst),
      .p_avg  (p_avg),
      .q_avg  (q_avg),
      .v_rms  (v_rms),
      .i_rms  (i_rms)
  );

  // 4. THD Analyzer
  thd_analyzer #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) u_thd (
      .clk          (clk),
      .rst_n        (rst_n),
      .measure_en   (measure_en),
      .v_in         (v_in),
      .v_alpha      (v_alpha),
      .v_beta       (v_beta),
      .pll_locked   (pll_locked),
      .thd_val      (thd_val),
      .thd_12c      (thd_12c),
      .update_strobe(uart_update_strobe)
  );

endmodule
