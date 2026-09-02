`timescale 1ns / 1ps

module uart_baud_gen #(
    parameter BAUD_RATE  = 9600,
    parameter CLK_FREQ   = 100_000_000,
    parameter OVERSAMPLE = 1,
    parameter ACC_WIDTH  = 32
) (
    input  wire clk,
    input  wire rst,
    output reg  baud,
    output reg  baud_tick
);

  localparam BAUD_ACC = ((64'd1 * BAUD_RATE * OVERSAMPLE) << ACC_WIDTH) / CLK_FREQ;  // <-- correct order

  reg [ACC_WIDTH-1:0] acc = 0;

  always @(posedge clk) begin
    if (rst) begin
      acc       <= 0;
      baud      <= 1;
      baud_tick <= 0;
    end else begin
      {baud_tick, acc} <= acc + BAUD_ACC;  // baud_tick = overflow (MSB carry)
      if (baud_tick) baud <= ~baud;
    end
  end

endmodule
