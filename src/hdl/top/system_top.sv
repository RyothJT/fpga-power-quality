`timescale 1ns / 1ps

module system_top #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0
) (
    input  logic        clk,
    input  logic        rst_n,

    // DDS Control Inputs
    input  logic [23:0] center_freq,    // Frequency in Q16.8 format (e.g., 60 Hz = 24'd15360)
    input  logic [14:0] v_peak,         // Voltage magnitude scaling (Q0.15)
    input  logic [14:0] i_peak,         // Current magnitude scaling (Q0.15)
    input  logic        jitter_en,
    input  logic [ 3:0] jitter_depth,
    input  logic [ 7:0] current_phase,

    // Voltage Harmonic Controls (Q0.8)
    input  logic [ 7:0] v_h3_scale,
    input  logic [ 7:0] v_h5_scale,
    input  logic [ 7:0] v_h7_scale,

    // Current Harmonic Controls (Q0.8)
    input  logic [ 7:0] i_h3_scale,
    input  logic [ 7:0] i_h5_scale,
    input  logic [ 7:0] i_h7_scale,

    // SOGI-PLL Control Inputs
    input  logic signed [15:0] k_sogi,  // 16'sd16384 = 1.0 (Q1.14)
    input  logic signed [15:0] kp_pll,  // Proportional gain
    input  logic signed [15:0] ki_pll,  // Integral gain

    // Synthesized Signals Output
    output logic signed [15:0] v_out,
    output logic signed [15:0] i_out,

    // SOGI-PLL Telemetry Outputs
    output logic signed [15:0] v_alpha,
    output logic signed [15:0] v_beta,
    output logic signed [15:0] v_d,
    output logic signed [15:0] v_q,
    output logic        [15:0] theta,
    output logic        [15:-8] freq_out,
    output logic               pll_locked
);

  // Synchronous Reset Inversion for DDS (DDS expects active-high reset)
  wire dds_rst = ~rst_n;

  // -------------------------------------------------------------------------
  // 1. Direct Digital Synthesizer (DDS) Generator Core
  // -------------------------------------------------------------------------
  dds_top #(
      .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
  ) u_dds (
      .clk          (clk),
      .rst          (dds_rst),
      .center_freq  (center_freq),
      .v_peak       (v_peak),
      .i_peak       (i_peak),
      .jitter_en    (jitter_en),
      .jitter_depth (jitter_depth),
      .current_phase(current_phase),
      .v_h3_scale   (v_h3_scale),
      .v_h5_scale   (v_h5_scale),
      .v_h7_scale   (v_h7_scale),
      .i_h3_scale   (i_h3_scale),
      .i_h5_scale   (i_h5_scale),
      .i_h7_scale   (i_h7_scale),
      .v_out        (v_out),
      .i_out        (i_out)
  );

  // -------------------------------------------------------------------------
  // 2. Second-Order Generalized Integrator PLL (SOGI-PLL)
  // -------------------------------------------------------------------------
  sogi_pll_top #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_pll (
      .clk       (clk),
      .rst_n     (rst_n),
      .v_in      (v_out),       // Drive PLL with synthesized grid voltage
      .k_sogi    (k_sogi),
      .kp_pll    (kp_pll),
      .ki_pll    (ki_pll),
      .v_alpha   (v_alpha),
      .v_beta    (v_beta),
      .v_d       (v_d),
      .v_q       (v_q),
      .theta     (theta),
      .freq_out  (freq_out),
      .pll_locked(pll_locked)
  );

endmodule
