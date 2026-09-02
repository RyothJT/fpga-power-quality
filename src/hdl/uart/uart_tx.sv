`timescale 1ns / 1ps

module uart_tx #(
    parameter DATA_BITS = 8,
    parameter BAUD_RATE = 9600,
    parameter CLK_FREQ  = 100_000_000
) (
    input wire clk,
    input wire rst,
    input wire tx_start,
    input wire [(DATA_BITS - 1):0] tx_data,
    output reg RsTx,
    output reg busy
);

  wire baud_tick;

  uart_baud_gen #(
      .BAUD_RATE(BAUD_RATE),
      .CLK_FREQ (CLK_FREQ)
  ) baud_gen (
      .clk(clk),
      .rst(rst),
      .baud_tick(baud_tick)
  );

  typedef enum logic [2:0] {
    IDLE,
    START,
    DATA,
    STOP
  } state_t;

  state_t state;
  reg [3:0] bit_counter;
  reg [(DATA_BITS - 1):0] latched_data;
  reg latched;

  always @(posedge clk) begin
    if (rst) begin
      state        <= IDLE;
      RsTx         <= 1;
      bit_counter  <= 0;
      latched_data <= 0;
      busy         <= 1;
      latched      <= 0;
    end else begin
      case (state)
        IDLE: begin
          RsTx <= 1;

          if (tx_start) begin
            latched_data <= tx_data;
            latched <= 1;
            busy <= 1;
          end else if (!latched) busy <= 0;

          if (baud_tick & latched) begin
            latched <= 0;
            state   <= START;
          end
        end

        START: begin
          RsTx <= 0;
          if (baud_tick) begin
            state       <= DATA;
            bit_counter <= 0;
          end
        end

        DATA: begin
          RsTx <= latched_data[bit_counter];
          if (baud_tick) begin
            bit_counter <= bit_counter + 1;
            if (bit_counter == DATA_BITS - 1) state <= STOP;
          end
        end

        STOP: begin
          RsTx  <= 1;
          // Deassert busy immediately after stop bit
          state <= IDLE;  // Ends exactly on the stop bit
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
