`timescale 1ns / 1ps

module dds_top #(
    parameter PHASE_ACC_WIDTH = 32,
    parameter real CLOCK_FREQ_HZ = 100_000_000.0
) (
    input wire clk,
    input wire rst,

    // Dynamic Frequency Control (Q16.8 Hz format)
    input wire [23:0] center_freq,

    // Primary Wave Amplitude Controls
    input wire [14:0] v_peak,        // Q0.15 unsigned
    input wire [14:0] i_peak,        // Q0.15 unsigned
    input wire        jitter_en,
    input wire [ 3:0] jitter_depth,
    input wire [ 7:0] current_phase,

    // Voltage Harmonics (Q0.8)
    input wire [7:0] v_h3_scale,
    input wire [7:0] v_h5_scale,
    input wire [7:0] v_h7_scale,

    // Current Harmonics (Q0.8)
    input wire [7:0] i_h3_scale,
    input wire [7:0] i_h5_scale,
    input wire [7:0] i_h7_scale,

    output wire [15:0] v_out,
    output wire [15:0] i_out
);

  // -------------------------------------------------------------------------
  // Base Phase Increment Calculation (Uncorrupted by Jitter)
  // -------------------------------------------------------------------------
  localparam real SCALE_R = (16777216.0 / CLOCK_FREQ_HZ) * 65536.0;
  localparam logic [31:0] FREQ_MULT = 32'($rtoi(SCALE_R));

  wire [55:0] m_base_full = 56'(center_freq) * 56'(FREQ_MULT);
  wire [31:0] m_base = m_base_full[47:16];

  reg  [31:0] phase_acc;

  // Ideal, un-jittered phase accumulator step guarantees 60.000 Hz center
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      phase_acc <= 32'd0;
    end else begin
      phase_acc <= phase_acc + m_base;
    end
  end

  // -------------------------------------------------------------------------
  // LFSR & Post-Accumulator Phase Jitter Injection (Scaled)
  // -------------------------------------------------------------------------
  wire [15:0] rnd_word;

  lfsr_random u_lfsr (
      .clk(clk),
      .rst(rst),
      .rnd_out(rnd_word)
  );

  // Attenuate LFSR output so jitter_depth maxes out at a manageable phase window
  // Shift right by 4 base bits + (8 - jitter_depth)
  // Depth 8 -> max +/-8 ROM steps (+/- 11.25 degrees)
  // Depth 1 -> max +/-1 ROM step  (+/- 1.4 degrees)
  wire signed [7:0] phase_jitter = jitter_en ? ($signed(
      rnd_word[15:8]
  ) >>> (12 - jitter_depth)) : 8'sd0;

  // Add phase noise directly to ROM address bus
  wire [7:0] phase_jittered = phase_acc[31:24] + $unsigned(phase_jitter);

  // -------------------------------------------------------------------------
  // Address Generation
  // -------------------------------------------------------------------------
  wire [7:0] v_addr_h1 = phase_jittered;
  wire [7:0] i_addr_h1 = phase_jittered + current_phase;

  wire [7:0] v_addr_h3 = v_addr_h1 * 8'd3;
  wire [7:0] v_addr_h5 = v_addr_h1 * 8'd5;
  wire [7:0] v_addr_h7 = v_addr_h1 * 8'd7;

  wire [7:0] i_addr_h3 = i_addr_h1 * 8'd3;
  wire [7:0] i_addr_h5 = i_addr_h1 * 8'd5;
  wire [7:0] i_addr_h7 = i_addr_h1 * 8'd7;

  // -------------------------------------------------------------------------
  // ROM Lookups
  // -------------------------------------------------------------------------
  wire signed [15:0] raw_v_h1, raw_v_h3, raw_v_h5, raw_v_h7;
  wire signed [15:0] raw_i_h1, raw_i_h3, raw_i_h5, raw_i_h7;

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

  // -------------------------------------------------------------------------
  // Weighted Sum & Scaling
  // -------------------------------------------------------------------------
  wire signed [23:0] v_h3_w = raw_v_h3 * $signed({1'b0, v_h3_scale});
  wire signed [23:0] v_h5_w = raw_v_h5 * $signed({1'b0, v_h5_scale});
  wire signed [23:0] v_h7_w = raw_v_h7 * $signed({1'b0, v_h7_scale});

  wire signed [23:0] i_h3_w = raw_i_h3 * $signed({1'b0, i_h3_scale});
  wire signed [23:0] i_h5_w = raw_i_h5 * $signed({1'b0, i_h5_scale});
  wire signed [23:0] i_h7_w = raw_i_h7 * $signed({1'b0, i_h7_scale});

  wire signed [17:0] v_comp = $signed(
      raw_v_h1
  ) + $signed(
      v_h3_w[23:8]
  ) + $signed(
      v_h5_w[23:8]
  ) + $signed(
      v_h7_w[23:8]
  );
  wire signed [17:0] i_comp = $signed(
      raw_i_h1
  ) + $signed(
      i_h3_w[23:8]
  ) + $signed(
      i_h5_w[23:8]
  ) + $signed(
      i_h7_w[23:8]
  );

  wire signed [32:0] v_scaled_full = v_comp * $signed({1'b0, v_peak});
  wire signed [32:0] i_scaled_full = i_comp * $signed({1'b0, i_peak});

  wire signed [17:0] v_scaled = v_scaled_full >>> 15;
  wire signed [17:0] i_scaled = i_scaled_full >>> 15;

  // -------------------------------------------------------------------------
  // Saturation Guard (Continuous Ternary Assignments)
  // -------------------------------------------------------------------------
  wire [15:0] v_sat, i_sat;
  assign v_sat = (v_scaled > 32'sd32767)  ? 16'sd32767  :
                      (v_scaled < -32'sd32768) ? -16'sd32768 :
                      v_scaled[15:0];

  assign i_sat = (i_scaled > 32'sd32767)  ? 16'sd32767  :
                      (i_scaled < -32'sd32768) ? -16'sd32768 :
                      i_scaled[15:0];

  assign v_out = v_sat;
  assign i_out = i_sat;

endmodule
