`timescale 1ns / 1ps

module dds_top #(
    parameter PHASE_ACC_WIDTH = 32
) (
    input  wire        clk,            // 100 MHz Basys 3 system clock
    input  wire        rst,            // Active-high reset
    input  wire        jitter_en,      // Enable phase jitter injection
    input  wire [ 3:0] jitter_depth,   // Jitter magnitude scaling (0 to 15)
    input  wire [ 8:0] sag_factor,     // Q0.8 scale factor (256 = 100%, 128 = 50% sag)
    input  wire [ 7:0] current_phase,  // Phase shift for Current signal I (0-255 maps to 0-360 deg)
    output wire [15:0] v_out,          // Voltage output sample (Q1.15 signed)
    output wire [15:0] i_out           // Current output sample (Q1.15 signed)
);

  // Baseline Tuning Word for 60 Hz output at 100 MHz System Clock:
  // M = (60 * 2^32) / 100,000,000 = 257698
  localparam [31:0] M_BASE = 32'd257698;

  reg [31:0] phase_acc;
  wire [15:0] rnd_word;
  wire signed [15:0] raw_v_sine;
  wire signed [15:0] raw_i_sine;

  // Instantiate LFSR Jitter Source
  lfsr_random u_lfsr (
      .clk(clk),
      .rst(rst),
      .rnd_out(rnd_word)
  );

  // Calculate dynamic phase increment (M_BASE + Jitter)
  wire signed [15:0] jitter_val = jitter_en ? ($signed(rnd_word) >>> (16 - jitter_depth)) : 16'd0;
  wire [31:0] m_actual = M_BASE + {{16{jitter_val[15]}}, jitter_val};

  // Phase Accumulator
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      phase_acc <= 32'd0;
    end else begin
      phase_acc <= phase_acc + m_actual;
    end
  end

  // Address extraction (Top 8 bits of phase accumulator)
  wire [7:0] v_addr = phase_acc[31:24];
  wire [7:0] i_addr = phase_acc[31:24] + current_phase;

  // Instantiate Sine ROM for Voltage (V)
  dds_sine_rom u_rom_v (
      .clk(clk),
      .addr(v_addr),
      .sine_out(raw_v_sine)
  );

  // Instantiate Sine ROM for Current (I)
  dds_sine_rom u_rom_i (
      .clk(clk),
      .addr(i_addr),
      .sine_out(raw_i_sine)
  );

  // Apply Voltage Sag scaling (Fixed-point multiplication: Q1.15 * Q0.8 >> 8)
  wire signed [23:0] v_scaled = raw_v_sine * $signed({1'b0, sag_factor});
  wire signed [23:0] i_scaled = raw_i_sine * $signed({1'b0, sag_factor});

  assign v_out = v_scaled[23:8];
  assign i_out = i_scaled[23:8];

endmodule
