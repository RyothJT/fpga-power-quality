`timescale 1ns / 1ps

module dds_top #(
    parameter      PHASE_ACC_WIDTH       = 32,
    parameter real CLOCK_FREQ_HZ         = 100_000_000.0,
    // Consistently divide by 100 to match real world conditions with faster simulation
    parameter real TARGET_SAMPLE_RATE_HZ = CLOCK_FREQ_HZ / 100  // 1_000_000.0
    // For realistic simulation at lower clock frequencies
    // parameter real TARGET_SAMPLE_RATE_HZ = $min(1_000_000.0, CLOCK_FREQ_HZ)
) (
    input wire clk,
    input wire rst,

    output reg sample_en,
    output reg measure_en,

    // Dynamic Bit Precision Control (e.g., 16, 12, 10, 8)
    input wire [4:0] bit_precision,

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
  // Clock Divider & Base Phase Increment Calculation
  // -------------------------------------------------------------------------
  localparam integer DIV_LIMIT = $rtoi(CLOCK_FREQ_HZ / TARGET_SAMPLE_RATE_HZ);
  reg [31:0] clk_div_cnt;

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      clk_div_cnt <= 32'd0;
      sample_en   <= 1'b0;
      measure_en  <= 1'b0;
    end else begin
      // Existing sample_en logic (Leading Edge)
      sample_en  <= (clk_div_cnt == DIV_LIMIT - 1);
      // New measure_en logic (Midpoint)
      // This aligns the continuous SOGI fundamental with the center of the DDS step
      measure_en <= (clk_div_cnt == (DIV_LIMIT >> 1));
      if (clk_div_cnt >= DIV_LIMIT - 1) clk_div_cnt <= 32'd0;
      else clk_div_cnt <= clk_div_cnt + 1'b1;
    end
  end

  localparam real SCALE_R = (16777216.0 / TARGET_SAMPLE_RATE_HZ) * 65536.0;
  localparam logic [31:0] FREQ_MULT = 32'($rtoi(SCALE_R));

  wire [55:0] m_base_full = 56'(center_freq) * 56'(FREQ_MULT);
  wire [31:0] m_base = m_base_full[47:16];

  reg  [31:0] phase_acc;

  // Ideal, un-jittered phase accumulator step guarantees 60.000 Hz center at 1 MSPS
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      phase_acc <= 32'd0;
    end else if (sample_en) begin
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
  // Saturation Guard
  // -------------------------------------------------------------------------
  wire [15:0] v_sat, i_sat;
  assign v_sat = (v_scaled > 32'sd32767)  ? 16'sd32767  :
                 (v_scaled < -32'sd32768) ? -16'sd32768 :
                 v_scaled[15:0];

  assign i_sat = (i_scaled > 32'sd32767)  ? 16'sd32767  :
                 (i_scaled < -32'sd32768) ? -16'sd32768 :
                 i_scaled[15:0];

  // -------------------------------------------------------------------------
  // Dynamic Bit Precision Masking (Zeroes lower 16 - bit_precision bits)
  // -------------------------------------------------------------------------
  wire [ 3:0] shift_amt = (bit_precision < 5'd16) ? (5'd16 - bit_precision) : 4'd0;
  wire [15:0] precision_mask = 16'hFFFF << shift_amt;

  assign v_out = v_sat & precision_mask;
  assign i_out = i_sat & precision_mask;

endmodule
