`timescale 1ns / 1ps

/**
 * Module: sogi_sine_rom
 * Description: Dual-output lookup table providing simultaneous Sin and Cos values (Q1.14).
 */
module sogi_sine_rom (
    input  logic               clk,
    input  logic        [ 7:0] phase_addr,
    output logic signed [15:0] sin_val,
    output logic signed [15:0] cos_val
);

  // Quarter-wave or full 256-entry Q1.14 sine table
  logic signed [15:0] sin_lut[0:255];

  initial begin
    // Standard initialized values for test/synthesis (replace with $readmemh if using external COE/MEM file)
    for (int i = 0; i < 256; i++) begin
      sin_lut[i] = $rtoi(16383.0 * $sin(2.0 * 3.141592653589793 * i / 256.0));
    end
  end

  always_ff @(posedge clk) begin
    sin_val <= sin_lut[phase_addr];
    cos_val <= sin_lut[phase_addr+8'd64];  // Cosine is Phase + 90 degrees (64 steps)
  end

endmodule
