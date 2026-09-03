`timescale 1ns / 1ps

/**
 * Module: system_top
 * Description: Top-level integration module connecting DDS signal generation,
 *              Voltage SOGI-PLL tracking, Current SOGI-QSG phase generation,
 *              and instantaneous/average power calculation engine.
 */
module system_top #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0,
    parameter BAUD_RATE = 115200
) (
    input logic clk,
    input logic rst_n,

    // DDS Signal Synthesizer Controls
    input logic [23:0] center_freq,    // Frequency in Q16.8 format (e.g., 60 Hz = 24'd15360)
    input logic [ 4:0] bit_precision,
    input logic [14:0] v_peak,         // Voltage magnitude scaling (Q0.15)
    input logic [14:0] i_peak,         // Current magnitude scaling (Q0.15)
    input logic        jitter_en,
    input logic [ 3:0] jitter_depth,
    input logic [ 7:0] current_phase,

    // Voltage Harmonic Controls (Q0.8)
    input logic [7:0] v_h3_scale,
    input logic [7:0] v_h5_scale,
    input logic [7:0] v_h7_scale,

    // Current Harmonic Controls (Q0.8)
    input logic [7:0] i_h3_scale,
    input logic [7:0] i_h5_scale,
    input logic [7:0] i_h7_scale,

    // SOGI Control Gains
    input logic signed [15:0] k_sogi,  // Gain factor (16'sd16384 = 1.0, Q1.14)
    input logic signed [15:0] kp_pll,  // Proportional gain for PLL
    input logic signed [15:0] ki_pll,  // Integral gain for PLL

    // Synthesized Line Waveforms
    output logic signed [15:0] v_out,
    output logic signed [15:0] i_out,

    // Voltage Quadrature & PLL Telemetry
    output logic signed [ 15:0] v_alpha,
    output logic signed [ 15:0] v_beta,
    output logic signed [ 15:0] v_d,
    output logic signed [ 15:0] v_q,
    output logic        [ 15:0] theta,
    output logic        [15:-8] freq_out,
    output logic                pll_locked,

    // Current Quadrature Outputs
    output logic signed [15:0] i_alpha,
    output logic signed [15:0] i_beta,

    // Power Engine Calculated Metrics
    output logic signed [15:0] p_inst,
    output logic signed [15:0] q_inst,
    output logic signed [15:0] p_avg,
    output logic signed [15:0] q_avg,
    output logic        [15:0] v_rms,
    output logic        [15:0] i_rms,

    // Total harmonic distortion metric
    output logic [3:-12] thd_val,
    output logic [3:-12] thd_12c,

    // UART for diagnostics
    output logic uart_busy,
    output logic uart_tx_out
);

  // -------------------------------------------------------------------------
  // Reset Inversion for DDS Sub-module
  // -------------------------------------------------------------------------
  wire dds_rst = ~rst_n;
  wire measure_en;

  wire uart_update_strobe;

  // 0. Diagnostics Transmitter
  diagnostic_transmitter #(
      .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ),
      .BAUD_RATE(BAUD_RATE)
  ) u_diag (
      .clk(clk),
      .rst(~rst_n),
      .update_strobe(uart_update_strobe),
      .v_rms(v_rms),
      .thd_12c(thd_val),  // Or your 12-cycle version
      .p_avg(p_avg),
      .RsTx(uart_tx_out),  // Map to physical pin
      .busy(),
      .tx_start(),
      .tx_data()
  );

  // -------------------------------------------------------------------------
  // 1. Direct Digital Synthesizer (DDS) Core
  // -------------------------------------------------------------------------
  dds_top #(
      .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
  ) u_dds (
      .clk          (clk),
      .rst          (dds_rst),
      .sample_en    (),
      .measure_en   (measure_en),
      .center_freq  (center_freq),
      .bit_precision(bit_precision),
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
  // 2. Grid Frontend (Vectorization Layer)
  //    Handles SOGI-PLL for Voltage and Frequency-Slaved QSG for Current.
  // -------------------------------------------------------------------------
  grid_frontend #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_frontend (
      .clk       (clk),
      .rst_n     (rst_n),
      .v_in      (v_out),
      .i_in      (i_out),
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

  // -------------------------------------------------------------------------
  // 3. Power & RMS Metrics Engine
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // 4. THD
  // -------------------------------------------------------------------------
  thd_analyzer #(
      .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
  ) u_thd (
      .clk          (clk),
      .rst_n        (rst_n),
      .measure_en   (measure_en),
      .v_in         (v_out),
      .v_alpha      (v_alpha),
      .v_beta       (v_beta),
      .pll_locked   (pll_locked),
      .thd_val      (thd_val),
      .thd_12c      (thd_12c),
      .update_strobe(uart_update_strobe)
  );

endmodule
