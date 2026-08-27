`timescale 1ns / 1ps

module lfsr_random (
    input  wire        clk,
    input  wire        rst,
    output wire [15:0] rnd_out
);

  reg [15:0] lfsr_reg;

  // Polynomial x^16 + x^14 + x^13 + x^11 + 1
  wire feedback = lfsr_reg[15] ^ lfsr_reg[13] ^ lfsr_reg[12] ^ lfsr_reg[10];

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      lfsr_reg <= 16'hACE1;  // Non-zero seed
    end else begin
      lfsr_reg <= {lfsr_reg[14:0], feedback};
    end
  end

  assign rnd_out = lfsr_reg;

endmodule
