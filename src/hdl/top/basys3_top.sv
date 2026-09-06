module basys3_top (
    input  logic        clk,
    input  logic        btnC,  // Reset (Center Button)
    input  logic [15:0] sw,    // 16 physical switches
    output logic [15:0] led,   // 16 physical LEDs
    output logic        RsTx   // UART TX Pin
);

  // -------------------------------------------------------------------------
  // 1. Control Signals (Required for .* connection)
  // -------------------------------------------------------------------------
  logic [23:0] center_freq;  // 60.0 Hz
  logic [ 4:0] bit_precision = 5'd12;
  logic [14:0] v_peak;
  logic [14:0] i_peak = 15'h3FFF;
  logic        jitter_en;
  logic [ 3:0] jitter_depth = 4'd4;
  logic [ 7:0] current_phase = 8'd32;  // ~45 deg lag

  // Harmonic Scales (Q0.8)
  logic [7:0] v_h3_scale, v_h5_scale, v_h7_scale;
  logic [7:0] i_h3_scale, i_h5_scale, i_h7_scale;

  // SOGI Control Gains
  logic signed [15:0] k_sogi = 16'sd8192;
  logic signed [15:0] kp_pll = 16'sd120;
  logic signed [15:0] ki_pll = 16'sd40;

  // -------------------------------------------------------------------------
  // 2. Telemetry Wires (Required for .* connection)
  // -------------------------------------------------------------------------
  logic signed [15:0] v_out, i_out;
  logic signed [15:0] v_alpha, v_beta, v_d, v_q;
  logic [ 15:0] theta;
  logic [15:-8] freq_out;
  logic         pll_locked;

  logic signed [15:0] i_alpha, i_beta;
  logic signed [15:0] p_inst, q_inst, p_avg, q_avg;
  logic [15:0] v_rms, i_rms;
  logic [3:-12] thd_val, thd_12c;

  logic uart_busy;

  // -------------------------------------------------------------------------
  // 3. Physical Mappings
  // -------------------------------------------------------------------------

  // sw[4:0] selects 0 to 30, mapping directly to 45 Hz through 75 Hz
  // Base offset = 45 Hz * 256 = 11520
  // Step per bit = 1 Hz * 256 = 256 (equivalent to left-shifting by 8)
  assign center_freq = 24'd11520 + ({19'd0, sw[4:0]} << 8);

  assign v_peak      = sw[11] ? 16'h1FFF: 16'h3FFF; // 50% voltage drop
  assign v_h3_scale  = sw[12] ? 8'd38 : 8'd0;  // ~15% 3rd harmonic
  assign v_h5_scale  = sw[13] ? 8'd19 : 8'd0;  // ~7.5% 5th harmonic
  assign v_h7_scale  = sw[14] ? 8'd10 : 8'd0;  // ~4% 7th harmonic
  assign jitter_en   = sw[15];

  // Tie unused harmonics to 0
  assign i_h3_scale  = 8'd0;
  assign i_h5_scale  = 8'd0;
  assign i_h7_scale  = 8'd0;

  // -------------------------------------------------------------------------
  // 4. Instantiate System Top
  // -------------------------------------------------------------------------
  system_top u_system (
      .clk        (clk),
      .rst_n      (~btnC),     // btnC is active-high on Basys 3
      .uart_tx_out(RsTx),      // Map to physical UART pin
      .uart_busy  (uart_busy),
      .*  // Wildcard connects all wires declared above
  );

  // -------------------------------------------------------------------------
  // 5. LED Visual Feedback
  // -------------------------------------------------------------------------
  assign led[0]    = pll_locked;
  assign led[15]   = uart_busy;
  assign led[14:1] = q_inst[13:0]; // Show voltage magnitude

endmodule
