`timescale 1ns / 1ps

module grid_frontend #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0
) (
    input logic clk,
    input logic rst_n,

    // Raw Inputs
    input logic signed [15:0] v_in,
    input logic signed [15:0] i_in,

    // Control Gains
    input logic signed [15:0] k_sogi,
    input logic signed [15:0] kp_pll,
    input logic signed [15:0] ki_pll,

    // Vectorized Outputs
    output logic signed [15:0] v_alpha, v_beta,
    output logic signed [15:0] i_alpha, i_beta,

    // Telemetry & Status
    output logic signed [15:0] v_d, v_q,
    output logic        [15:0] theta,
    output logic        [15:-8] freq_out,
    output logic               pll_locked
);

  // Shared Frequency Bus
  logic [31:0] system_phase_inc;

  // -------------------------------------------------------------------------
  // 1. Voltage Path: SOGI-PLL (The Master)
  // -------------------------------------------------------------------------
  sogi_pll_top #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_v_pll (
      .clk               (clk),
      .rst_n             (rst_n),
      .v_in              (v_in),
      .k_sogi            (k_sogi),
      .kp_pll            (kp_pll),
      .ki_pll            (ki_pll),
      .v_alpha           (v_alpha),
      .v_beta            (v_beta),
      .v_d               (v_d),
      .v_q               (v_q),
      .theta             (theta),
      .freq_out          (freq_out),
      .pll_locked        (pll_locked),
      .phase_inc_smoothed(system_phase_inc) // Export frequency bus
  );

  // -------------------------------------------------------------------------
  // 2. Current Path: SOGI-QSG (The Slave)
  // -------------------------------------------------------------------------
  sogi_qsg #(
      .CLOCK_FREQ_HZ    (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ   (CENTER_FREQ_HZ),
      .ENABLE_FREQ_ADAPT(1)                 // Enable coupling to PLL
  ) u_i_qsg (
      .clk         (clk),
      .rst_n       (rst_n),
      .u_in        (i_in),
      .k_sogi      (k_sogi),
      .phase_inc_in(system_phase_inc),      // Slave to Voltage Frequency
      .u_alpha     (i_alpha),
      .u_beta      (i_beta)
  );

endmodule
