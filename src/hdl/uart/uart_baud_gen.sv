`timescale 1ns / 1ps

module uart_baud_gen #(
    parameter int  BAUD_RATE  = 115200,
    parameter real CLK_FREQ   = 100_000_000.0,
    parameter int  OVERSAMPLE = 1               // 1 for TX, 16 for RX
) (
    input  logic clk,
    input  logic rst,
    output logic baud_tick
);

  // 1. Calculate the divisor as a standard integer
  // Vivado handles this math perfectly during synthesis
  localparam int CLK_INT = $rtoi(CLK_FREQ);
  localparam int DIVISOR = CLK_INT / (BAUD_RATE * OVERSAMPLE);

  // 2. Counter width automatically sized by $clog2
  logic [$clog2(DIVISOR)-1:0] counter;

  always_ff @(posedge clk) begin
    if (rst) begin
      counter   <= '0;
      baud_tick <= 1'b0;
    end else begin
      if (counter >= (DIVISOR - 1)) begin
        counter   <= '0;
        baud_tick <= 1'b1;  // Pulse for one clock cycle
      end else begin
        counter   <= counter + 1'b1;
        baud_tick <= 1'b0;
      end
    end
  end

endmodule
