`timescale 1ns / 1ps

module diagnostic_transmitter #(
    parameter int BAUD_RATE   = 115200,
    parameter int NUM_SIGNALS = 7
) (
    input logic clk,
    input logic rst,
    input logic update_strobe,  // From THD Analyzer
    input logic force_strobe,   // From Top Level

    input logic [15:0] v_rms,
    i_rms,
    p_avg,
    q_avg,
    v_q,
    freq,
    thd_12c,
    input logic        locked,

    output logic RsTx,
    output logic busy
);

  localparam int PACKET_SIZE = 2 + (NUM_SIGNALS * 2) + 1;  // 17 bytes

  typedef enum logic [1:0] {
    IDLE,
    SEND_BYTE,
    WAIT_ACK,
    WAIT_DONE
  } state_t;
  state_t        state;

  logic   [ 7:0] packet             [PACKET_SIZE];
  logic   [ 4:0] byte_idx;
  logic   [ 7:0] tx_buffer_data;
  logic          tx_buffer_start;
  wire           uart_busy_int;

  // --- Internal Heartbeat (Triggers every 0.5s if top-level fails) ---
  logic   [26:0] internal_heartbeat;
  always_ff @(posedge clk) begin
    if (rst) internal_heartbeat <= 0;
    else internal_heartbeat <= internal_heartbeat + 1;
  end
  wire local_trigger = (internal_heartbeat == 27'd50_000_000);

  // --- PACKET MAP ---
  always_comb begin
    packet[0]  = 8'hAA;
    packet[1]  = {7'b0, locked};
    packet[2]  = v_rms[15:8];
    packet[3]  = v_rms[7:0];
    packet[4]  = i_rms[15:8];
    packet[5]  = i_rms[7:0];
    packet[6]  = p_avg[15:8];
    packet[7]  = p_avg[7:0];
    packet[8]  = q_avg[15:8];
    packet[9]  = q_avg[7:0];
    packet[10] = v_q[15:8];
    packet[11] = v_q[7:0];
    packet[12] = freq[15:8];
    packet[13] = freq[7:0];
    packet[14] = thd_12c[15:8];
    packet[15] = thd_12c[7:0];
    packet[16] = 8'h55;
  end

  uart_tx #(
      .BAUD_RATE(BAUD_RATE)
  ) u_uart (
      .clk(clk),
      .rst(rst),
      .tx_start(tx_buffer_start),
      .tx_data(tx_buffer_data),
      .RsTx(RsTx),
      .busy(uart_busy_int)
  );

  assign busy = uart_busy_int;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      byte_idx <= 0;
      tx_buffer_start <= 0;
      tx_buffer_data <= 0;
    end else begin
      tx_buffer_start <= 0;

      case (state)
        IDLE: begin
          if (update_strobe || force_strobe || local_trigger) begin
            byte_idx <= 0;
            state    <= SEND_BYTE;
          end
        end

        SEND_BYTE: begin
          if (!uart_busy_int) begin
            tx_buffer_data  <= packet[byte_idx];
            tx_buffer_start <= 1;
            state           <= WAIT_ACK;
          end
        end

        WAIT_ACK: begin
          // Wait for UART to register the start pulse
          state <= WAIT_DONE;
        end

        WAIT_DONE: begin
          // Wait for UART to finish the 10-bit frame (Start + 8 Data + Stop)
          if (!uart_busy_int) begin
            if (byte_idx == PACKET_SIZE - 1) begin
              state <= IDLE;
            end else begin
              byte_idx <= byte_idx + 1;
              state    <= SEND_BYTE;
            end
          end
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule
