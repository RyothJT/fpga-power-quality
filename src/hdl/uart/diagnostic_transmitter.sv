`timescale 1ns / 1ps

module diagnostic_transmitter #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter      BAUD_RATE     = 115200
) (
    input logic clk,
    input logic rst,
    input logic update_strobe, // Pulse from THD analyzer (every 12 cycles)

    // Diagnostic Data
    input logic [15:0] v_rms,
    input logic [15:0] thd_12c,
    input logic [15:0] p_avg,

    // UART Interface
    output logic tx_start,
    output logic [7:0] tx_data,
    output logic busy,
    output logic RsTx
);

  typedef enum logic [3:0] {
    IDLE,
    SEND_HEADER,
    SEND_V_H,
    SEND_V_L,
    SEND_THD_H,
    SEND_THD_L,
    SEND_P_H,
    SEND_P_L,
    SEND_FOOTER,
    WAIT_BUSY
  } state_t;

  state_t state, next_state;
  logic [15:0] v_reg, thd_reg, p_reg;

  // Instantiate your UART TX core internally or externally
  uart_tx #(
      .BAUD_RATE(BAUD_RATE),  // Higher baud recommended for diagnostics
      .CLK_FREQ(CLOCK_FREQ_HZ)
  ) u_tx (
      .clk(clk),
      .rst(rst),
      .tx_start(tx_start),
      .tx_data(tx_data),
      .RsTx(RsTx),
      .busy(busy)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      tx_start <= 0;
      tx_data <= 8'h00;
    end else begin
      tx_start <= 0;  // Default pulse

      case (state)
        IDLE: begin
          if (update_strobe) begin
            // Latch data so it doesn't change mid-transmission
            v_reg   <= v_rms;
            thd_reg <= thd_12c;
            p_reg   <= p_avg;
            state   <= SEND_HEADER;
          end
        end

        SEND_HEADER:
        if (!busy) begin
          tx_data <= 8'hAA;  // Start of Frame
          tx_start <= 1;
          next_state <= SEND_V_H;
          state <= WAIT_BUSY;
        end

        SEND_V_H:
        if (!busy) begin
          tx_data <= v_reg[15:8];
          tx_start <= 1;
          next_state <= SEND_V_L;
          state <= WAIT_BUSY;
        end

        SEND_V_L:
        if (!busy) begin
          tx_data <= v_reg[7:0];
          tx_start <= 1;
          next_state <= SEND_THD_H;
          state <= WAIT_BUSY;
        end

        SEND_THD_H:
        if (!busy) begin
          tx_data <= thd_reg[15:8];
          tx_start <= 1;
          next_state <= SEND_THD_L;
          state <= WAIT_BUSY;
        end

        SEND_THD_L:
        if (!busy) begin
          tx_data <= thd_reg[7:0];
          tx_start <= 1;
          next_state <= SEND_P_H;
          state <= WAIT_BUSY;
        end

        SEND_P_H:
        if (!busy) begin
          tx_data <= p_reg[15:8];
          tx_start <= 1;
          next_state <= SEND_P_L;
          state <= WAIT_BUSY;
        end

        SEND_P_L:
        if (!busy) begin
          tx_data <= p_reg[7:0];
          tx_start <= 1;
          next_state <= SEND_FOOTER;
          state <= WAIT_BUSY;
        end

        SEND_FOOTER:
        if (!busy) begin
          tx_data <= 8'h55;  // End of Frame
          tx_start <= 1;
          next_state <= IDLE;
          state <= WAIT_BUSY;
        end

        WAIT_BUSY: begin
          // Small delay to let 'busy' signal from uart_tx assert
          if (busy) state <= next_state;
        end
      endcase
    end
  end
endmodule
