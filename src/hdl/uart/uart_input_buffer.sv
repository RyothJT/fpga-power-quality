`timescale 1ns / 1ps

module uart_input_buffer #(
    parameter DATA_BITS_IN = 8,
    parameter CLK_FREQ = 100_000_000,
    parameter BUFFER_SIZE = 1024  // in bytes
) (
    input clk,
    input rst,
    input [(DATA_BITS_IN - 1):0] data_in,
    input valid_in,
    input ready_out,
    output wire [(DATA_BITS_IN - 1):0] data_out,
    output wire valid_out,
    output wire ready_in         // This remains unused because the UART can not stop, but kept for modularity
);

  reg [7:0] buffer[0:(BUFFER_SIZE - 1)];

  reg [($clog2(BUFFER_SIZE) - 1) : 0] left_index;
  reg [($clog2(BUFFER_SIZE)) : 0] count;
  wire [($clog2(BUFFER_SIZE) - 1) : 0] right_index = left_index + count;

  assign valid_out = count > 0;
  assign ready_in  = count < BUFFER_SIZE;
  assign data_out  = buffer[left_index];

  always @(posedge clk) begin
    if (rst) begin
      left_index <= 0;
      count      <= 0;
    end else begin
      // Write
      if (valid_in && ready_in) begin
        buffer[right_index] <= data_in;
        count <= count + 1;
      end

      // Read
      if (ready_out && valid_out) begin
        left_index <= left_index + 1;
        count      <= count - 1;
      end
    end
  end


endmodule
