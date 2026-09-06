`timescale 1ns / 1ps

module basys3_top (
    input  logic        clk,
    input  logic        btnC,  // Reset (Center Button)
    input  logic [15:0] sw,    // 16 physical switches
    output logic [15:0] led,   // 16 physical LEDs
    output logic        RsTx,  // UART TX Pin

    // Physical Analog Pins (Must be in port list to map to XDC)
    input logic v_p,
    v_n,  // XA1 (VAUX6)
    input logic i_p,
    i_n  // XA2 (VAUX14)
);

  // -------------------------------------------------------------------------
  // 1. Internal Buses & Control
  // -------------------------------------------------------------------------
  logic [23:0] center_freq;
  logic [14:0] v_peak;
  logic [15:0] v_in, i_in;
  logic measure_en;

  // DDS HIL Wires
  logic [15:0] v_hil, i_hil;
  logic measure_hil;

  // XADC Real Wires
  logic [15:0] v_xadc, i_xadc;
  logic measure_xadc;

  // Debug Wires
  logic [11:0] xadc_v_raw, xadc_i_raw;
  logic adc_activity;

  // -------------------------------------------------------------------------
  // 2. Data Source Selection (Mux)
  //    sw[10] = 0: Internal DDS (HIL Mode)
  //    sw[10] = 1: External XADC (Real Mode)
  // -------------------------------------------------------------------------
  assign v_in       = sw[10] ? v_xadc : v_hil;
  assign i_in       = sw[10] ? i_xadc : i_hil;
  assign measure_en = sw[10] ? measure_xadc : measure_hil;

  // -------------------------------------------------------------------------
  // 3. Virtual Grid Generator (DDS)
  // -------------------------------------------------------------------------
  dds_top #(
      .CLOCK_FREQ_HZ (100_000_000.0),
      .SAMPLE_RATE_HZ(20_000.0)
  ) u_hil_grid (
      .clk          (clk),
      .rst          (btnC),
      .measure_en   (measure_hil),
      .center_freq  (center_freq),
      .bit_precision(5'd12),
      .v_peak       (v_peak),
      .i_peak       (15'h3FFF),
      .jitter_en    (sw[15]),
      .jitter_depth (4'd4),
      .current_phase(8'd32),
      .v_h3_scale   (sw[12] ? 8'd38 : 8'd0),
      .v_h5_scale   (sw[13] ? 8'd19 : 8'd0),
      .v_h7_scale   (sw[14] ? 8'd10 : 8'd0),
      .i_h3_scale   (8'd0),
      .i_h5_scale   (8'd0),
      .i_h7_scale   (8'd0),
      .v_out        (v_hil),
      .i_out        (i_hil)
  );

  // -------------------------------------------------------------------------
  // 4. Physical XADC Interface (Digilent-Style Wrapper)
  // -------------------------------------------------------------------------
  xadc_interface u_xadc (
      .clk_100m    (clk),
      .reset_n     (~btnC),
      .v_p         (v_p),
      .v_n         (v_n),
      .i_p         (i_p),
      .i_n         (i_n),
      .v_data_o    (v_xadc),
      .i_data_o    (i_xadc),
      .data_valid_o(measure_xadc),
      .activity_led(adc_activity),
      .raw_v_debug (xadc_v_raw),
      .raw_i_debug (xadc_i_raw)
  );

  // -------------------------------------------------------------------------
  // 5. Processing System (The "Brain")
  // -------------------------------------------------------------------------
  logic signed [15:0] v_alpha, v_beta, v_d, v_q;
  logic [15:0] theta, v_rms, i_rms;
  logic [15:-8] freq_out;
  logic pll_locked, uart_busy;
  logic signed [15:0] p_avg, q_avg, p_inst, q_inst;
  logic signed [15:0] i_alpha, i_beta;
  logic [3:-12] thd_val, thd_12c;

  system_top u_system (
      .clk        (clk),
      .rst_n      (~btnC),
      .v_in       (v_in),
      .i_in       (i_in),
      .measure_en (measure_en),
      .k_sogi     (16'sd8192),
      .kp_pll     (16'sd120),
      .ki_pll     (16'sd40),
      .uart_tx_out(RsTx),
      .*
  );

  // -------------------------------------------------------------------------
  // 6. Controls & Feedback
  // -------------------------------------------------------------------------
  assign center_freq = 24'd11520 + ({19'd0, sw[4:0]} << 8);
  assign v_peak      = sw[11] ? 15'h1FFF : 15'h3FFF;

  // LED FEEDBACK:
  assign led[11:0]   = sw[0] ? xadc_i_raw : xadc_v_raw;
  assign led[12]     = pll_locked;  // Locked indicator
  assign led[13]     = adc_activity;  // Toggles on ADC heartbeat
  assign led[14]     = 1'b0;  // Unused
  assign led[15]     = sw[10];  // Mode (High = Real)

endmodule
