`timescale 1ns / 1ps

/**
 * Module: pipelined_isqrt
 * Description: Calculates the integer square root of a 32-bit value over 16 clock cycles.
 *              Input: val_in (32-bit)
 *              Output: root_out (16-bit)
 *              Latency: 17 clock cycles (1 input stage + 16 calculation stages)
 */
module isqrt #(
    parameter int WIDTH = 32
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [    WIDTH-1:0] val_in,
    output logic [(WIDTH/2)-1:0] root_out
);

  localparam int STAGES = WIDTH / 2;

  // Internal pipeline registers
  // These hold the state of 'a' (input remaining), 'q' (result), and 'r' (remainder)
  logic [ WIDTH-1:0] a[0:STAGES];
  logic [STAGES-1:0] q[0:STAGES];
  logic [ WIDTH+1:0] r[0:STAGES];

  // Everything is handled in one block to avoid Icarus 'multi-driven' errors
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j <= STAGES; j++) begin
        a[j] <= '0;
        q[j] <= '0;
        r[j] <= '0;
      end
    end else begin
      // --- Stage 0: Sample Input ---
      a[0] <= val_in;
      q[0] <= '0;
      r[0] <= '0;

      // --- Stages 1 to 16: Iterative Root Calculation ---
      for (int i = 0; i < STAGES; i++) begin
        logic [WIDTH+1:0] next_r;
        logic [WIDTH+1:0] test_right;

        // Bit-pairing and remainder update
        next_r = {r[i][WIDTH-1:0], a[i][WIDTH-1:WIDTH-2]};
        test_right = {q[i], 2'b01};

        if (next_r >= test_right) begin
          r[i+1] <= next_r - test_right;
          q[i+1] <= {q[i][STAGES-2:0], 1'b1};
        end else begin
          r[i+1] <= next_r;
          q[i+1] <= {q[i][STAGES-2:0], 1'b0};
        end

        // Shift 'a' to process next pair of bits
        a[i+1] <= a[i] << 2;
      end
    end
  end

  // Result is valid STAGES+1 cycles after input
  assign root_out = q[STAGES];

endmodule
