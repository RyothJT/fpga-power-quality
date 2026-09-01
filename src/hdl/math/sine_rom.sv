`timescale 1ns / 1ps

module sine_rom #(
    parameter int ADDR_WIDTH = 12,      // 4096 samples
    parameter int DATA_WIDTH = 16,      // 16-bit signed
    parameter real AMPLITUDE = 32767.0  // Default to Q1.15
) (
    input  logic                    clk,
    input  logic [ADDR_WIDTH-1:0]   addr,
    output logic signed [DATA_WIDTH-1:0] sin_out,
    output logic signed [DATA_WIDTH-1:0] cos_out
);

  localparam int ROM_SIZE = 1 << ADDR_WIDTH;
  localparam int QUARTER_CYCLE = 1 << (ADDR_WIDTH - 2);

  logic signed [DATA_WIDTH-1:0] rom [ROM_SIZE];

  initial begin
    for (int i = 0; i < ROM_SIZE; i++) begin
      // Vivado synthesizes this $sin call into a fixed BRAM LUT
      rom[i] = $rtoi(AMPLITUDE * $sin(2.0 * 3.141592653589 * i / ROM_SIZE));
    end
  end

  always_ff @(posedge clk) begin
    sin_out <= rom[addr];
    // Cosine is Phase + 90 degrees
    cos_out <= rom[(addr + QUARTER_CYCLE) % ROM_SIZE];
  end

endmodule
