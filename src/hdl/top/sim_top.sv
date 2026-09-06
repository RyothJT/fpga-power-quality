`timescale 1ns / 1ps

/**
 * Module: sim_top
 * Description: Hardware-in-the-Loop (HIL) wrapper. 
 *              Connects dds_top (Virtual Grid) to system_top (DSP Engine).
 */
module sim_top #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0,
    parameter real SAMPLE_RATE_HZ = 20_000.0,
    parameter integer BAUD_RATE = 115200
) (
    input logic clk,
    input logic rst_n,

    // --- DDS Grid Controls (The "Knobs") ---
    input logic [23:0] center_freq,    // Q16.8 format
    input logic [ 4:0] bit_precision,
    input logic [14:0] v_peak,         // Q0.15
    input logic [14:0] i_peak,         // Q0.15
    input logic        jitter_en,
    input logic [ 3:0] jitter_depth,
    input logic [ 7:0] current_phase,

    // Harmonic Scaling (Q0.8)
    input logic [7:0] v_h3_scale,
    v_h5_scale,
    v_h7_scale,
    input logic [7:0] i_h3_scale,
    i_h5_scale,
    i_h7_scale,

    // --- SOGI/PLL Gain Controls ---
    input logic signed [15:0] k_sogi,
    input logic signed [15:0] kp_pll,
    input logic signed [15:0] ki_pll,

    // --- Monitor Outputs (From System Engine) ---
    output logic signed [ 15:0] v_sim_out,   // The raw "sampled" V
    output logic signed [ 15:0] i_sim_out,   // The raw "sampled" I
    output logic signed [ 15:0] v_alpha,
    v_beta,
    output logic signed [ 15:0] v_d,
    v_q,
    output logic        [ 15:0] theta,
    output logic        [15:-8] freq_out,
    output logic                pll_locked,
    output logic signed [ 15:0] p_avg,
    q_avg,
    output logic        [ 15:0] v_rms,
    i_rms,
    output logic        [3:-12] thd_12c,

    // UART
    output logic uart_busy,
    output logic uart_tx_out
);

  // Internal HIL signals
  logic signed [15:0] v_hil_bus;
  logic signed [15:0] i_hil_bus;
  logic               measure_strobe;

  // Output internal bus for simulation visibility
  assign v_sim_out = v_hil_bus;
  assign i_sim_out = i_hil_bus;

  // -------------------------------------------------------------------------
  // 1. Virtual Grid Generator (DDS)
  // -------------------------------------------------------------------------
  dds_top #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) u_dds (
      .clk          (clk),
      .rst          (~rst_n),
      .sample_en    (),
      .measure_en   (measure_strobe),  // Generates the 20kHz timing
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
      .v_out        (v_hil_bus),
      .i_out        (i_hil_bus)
  );

  // -------------------------------------------------------------------------
  // 2. Processing Engine (The DUT)
  // -------------------------------------------------------------------------
  system_top #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_system (
      .clk        (clk),
      .rst_n      (rst_n),
      .v_in       (v_hil_bus),
      .i_in       (i_hil_bus),
      .measure_en (measure_strobe),
      .k_sogi     (k_sogi),
      .kp_pll     (kp_pll),
      .ki_pll     (ki_pll),
      .v_alpha    (v_alpha),
      .v_beta     (v_beta),
      .v_d        (v_d),
      .v_q        (v_q),
      .theta      (theta),
      .freq_out   (freq_out),
      .pll_locked (pll_locked),
      .i_alpha    (),                // Floating or connect as needed
      .i_beta     (),
      .p_inst     (),
      .q_inst     (),
      .p_avg      (p_avg),
      .q_avg      (q_avg),
      .v_rms      (v_rms),
      .i_rms      (i_rms),
      .thd_val    (),
      .thd_12c    (thd_12c),
      .uart_busy  (uart_busy),
      .uart_tx_out(uart_tx_out)
  );

endmodule
