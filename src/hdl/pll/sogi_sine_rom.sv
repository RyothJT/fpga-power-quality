`timescale 1ns / 1ps

/**
 * Module: sogi_sine_rom
 * Description: 4096-entry lookup table providing simultaneous Sin and Cos values (Q1.14).
 */
module sogi_sine_rom (
    input  logic               clk,
    input  logic        [11:0] phase_addr,
    output logic signed [15:0] sin_val,
    output logic signed [15:0] cos_val
);

  // 4096-entry Q1.14 sine table
  logic signed [15:0] sin_lut[4096];

  initial begin
    for (int i = 0; i < 4096; i++) begin
      sin_lut[i] = $rtoi(16383.0 * $sin(2.0 * 3.14159265358979323846 * i / 4096.0));
    end
  end

  always_ff @(posedge clk) begin
    sin_val <= sin_lut[phase_addr];
    cos_val <= sin_lut[phase_addr + 12'd1024];  // Cosine is Phase + 90 degrees (1024 / 4096 = 1/4 cycle)
  end

endmodule
