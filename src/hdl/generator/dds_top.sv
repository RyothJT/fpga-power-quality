`timescale 1ns / 1ps

module dds_top #(
    parameter PHASE_ACC_WIDTH = 32
) (
    input wire clk,  // 100 MHz Basys 3 system clock
    input wire rst,  // Active-high reset

    // Anomaly Controls
    input wire       jitter_en,     // Enable phase jitter injection
    input wire [3:0] jitter_depth,  // Jitter magnitude scaling (0 to 15)
    input wire [7:0] sag_factor,    // range from 0-255, with 255 representing ~200% normal voltage
    input wire [7:0] current_phase, // Current fundamental phase offset (0-255 maps to 0-360 deg)

    // Voltage Harmonic Amplitude Controls (Q0.8 fixed-point: 0 = 0%, 25 = ~10%)
    input wire [7:0] v_h3_scale,  // 3rd Harmonic (180 Hz) amplitude weighting for V
    input wire [7:0] v_h5_scale,  // 5th Harmonic (300 Hz) amplitude weighting for V
    input wire [7:0] v_h7_scale,  // 7th Harmonic (420 Hz) amplitude weighting for V

    // Current Harmonic Amplitude Controls (Q0.8 fixed-point: 0 = 0%, 25 = ~10%)
    input wire [7:0] i_h3_scale,  // 3rd Harmonic (180 Hz) amplitude weighting for I
    input wire [7:0] i_h5_scale,  // 5th Harmonic (300 Hz) amplitude weighting for I
    input wire [7:0] i_h7_scale,  // 7th Harmonic (420 Hz) amplitude weighting for I

    output wire [15:0] v_out,  // Composite Voltage sample (Q1.15 signed)
    output wire [15:0] i_out   // Composite Current sample (Q1.15 signed)
);

  // Baseline Tuning Word for 60 Hz output at 100 MHz System Clock:
  // M = (60 * 2^32) / 100,000,000 = 257698
  localparam [31:0] M_BASE = 32'd257698;

  reg  [31:0] phase_acc;
  wire [15:0] rnd_word;

  // --- LFSR Jitter Source ---
  lfsr_random u_lfsr (
      .clk(clk),
      .rst(rst),
      .rnd_out(rnd_word)
  );

  // Dynamic phase increment (M_BASE + Jitter)
  wire signed [15:0] jitter_val = jitter_en ? ($signed(rnd_word) >>> (16 - jitter_depth)) : 16'd0;
  wire        [31:0] m_actual = M_BASE + {{16{jitter_val[15]}}, jitter_val};

  // --- Phase Accumulator ---
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      phase_acc <= 32'd0;
    end else begin
      phase_acc <= phase_acc + m_actual;
    end
  end

  // =========================================================================
  // Address Generation
  // =========================================================================
  // Fundamental Base Addresses (8-bit address depth)
  wire [7:0] v_addr_h1 = phase_acc[31:24];
  wire [7:0] i_addr_h1 = phase_acc[31:24] + current_phase;

  // Voltage Harmonic Addresses (Odd Multiples)
  wire [7:0] v_addr_h3 = v_addr_h1 * 8'd3;
  wire [7:0] v_addr_h5 = v_addr_h1 * 8'd5;
  wire [7:0] v_addr_h7 = v_addr_h1 * 8'd7;

  // Current Harmonic Addresses (Odd Multiples aligned to Current Phase)
  wire [7:0] i_addr_h3 = i_addr_h1 * 8'd3;
  wire [7:0] i_addr_h5 = i_addr_h1 * 8'd5;
  wire [7:0] i_addr_h7 = i_addr_h1 * 8'd7;

  // =========================================================================
  // ROM Lookups (Fundamental + Harmonics)
  // =========================================================================
  wire signed [15:0] raw_v_h1, raw_v_h3, raw_v_h5, raw_v_h7;
  wire signed [15:0] raw_i_h1, raw_i_h3, raw_i_h5, raw_i_h7;

  // Voltage ROM Lookups
  dds_sine_rom u_rom_v_h1 (
      .clk(clk),
      .addr(v_addr_h1),
      .sine_out(raw_v_h1)
  );
  dds_sine_rom u_rom_v_h3 (
      .clk(clk),
      .addr(v_addr_h3),
      .sine_out(raw_v_h3)
  );
  dds_sine_rom u_rom_v_h5 (
      .clk(clk),
      .addr(v_addr_h5),
      .sine_out(raw_v_h5)
  );
  dds_sine_rom u_rom_v_h7 (
      .clk(clk),
      .addr(v_addr_h7),
      .sine_out(raw_v_h7)
  );

  // Current ROM Lookups
  dds_sine_rom u_rom_i_h1 (
      .clk(clk),
      .addr(i_addr_h1),
      .sine_out(raw_i_h1)
  );
  dds_sine_rom u_rom_i_h3 (
      .clk(clk),
      .addr(i_addr_h3),
      .sine_out(raw_i_h3)
  );
  dds_sine_rom u_rom_i_h5 (
      .clk(clk),
      .addr(i_addr_h5),
      .sine_out(raw_i_h5)
  );
  dds_sine_rom u_rom_i_h7 (
      .clk(clk),
      .addr(i_addr_h7),
      .sine_out(raw_i_h7)
  );

  // =========================================================================
  // Fixed-Point Multipliers & Harmonic Summation
  // Multipliers: Q1.15 * Q0.8 >> 8 -> Q1.15
  // =========================================================================
  // Weighted Voltage Harmonics
  wire signed [23:0] v_h3_weighted = raw_v_h3 * $signed({1'b0, v_h3_scale});
  wire signed [23:0] v_h5_weighted = raw_v_h5 * $signed({1'b0, v_h5_scale});
  wire signed [23:0] v_h7_weighted = raw_v_h7 * $signed({1'b0, v_h7_scale});

  // Weighted Current Harmonics
  wire signed [23:0] i_h3_weighted = raw_i_h3 * $signed({1'b0, i_h3_scale});
  wire signed [23:0] i_h5_weighted = raw_i_h5 * $signed({1'b0, i_h5_scale});
  wire signed [23:0] i_h7_weighted = raw_i_h7 * $signed({1'b0, i_h7_scale});

  // Composite Sums (18-bit signed headroom preventing intermediate overflow)
  wire signed [17:0] v_composite = $signed(
      raw_v_h1
  ) + $signed(
      v_h3_weighted[23:8]
  ) + $signed(
      v_h5_weighted[23:8]
  ) + $signed(
      v_h7_weighted[23:8]
  );

  wire signed [17:0] i_composite = $signed(
      raw_i_h1
  ) + $signed(
      i_h3_weighted[23:8]
  ) + $signed(
      i_h5_weighted[23:8]
  ) + $signed(
      i_h7_weighted[23:8]
  );

// =========================================================================
  // Sag & Scale Adjustments (Q1.15 * Q1.8 >> 8)
  // =========================================================================
  wire signed [23:0] v_mult = v_composite * $signed({1'b0, sag_factor});
  wire signed [23:0] i_mult = i_composite * $signed({1'b0, sag_factor});

  wire signed [15:0] v_scaled = v_mult >>> 8;
  wire signed [15:0] i_scaled = i_mult >>> 8;

  // =========================================================================
  // Saturation Logic (-32768 to +32767)
  // =========================================================================
  reg signed [15:0] v_saturated;
  reg signed [15:0] i_saturated;

  always @(*) begin
    // Voltage Saturation
    if (v_scaled > 18'sd32767) v_saturated = 16'sd32767;
    else if (v_scaled < -18'sd32768) v_saturated = -16'sd32768;
    else v_saturated = v_scaled;

    // Current Saturation
    if (i_scaled > 18'sd32767) i_saturated = 16'sd32767;
    else if (i_scaled < -18'sd32768) i_saturated = -16'sd32768;
    else i_saturated = i_scaled;
  end

  assign v_out = v_saturated;
  assign i_out = i_saturated;

endmodule
