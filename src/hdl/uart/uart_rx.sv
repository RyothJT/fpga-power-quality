`timescale 1ns / 1ps

module uart_rx #(
    parameter ENABLE_ERRORS = 1,
    parameter DATA_BITS = 8,
    parameter BAUD_RATE = 9600,
    parameter CLK_FREQ = 100_000_000,
    parameter PARITY_EN = 0
) (
    input clk,
    input rst,
    input RsRx,
    input ready_in,
    output reg [(DATA_BITS - 1):0] rx_data,
    output reg valid_out,

    output wire [2:0] status
);

  generate
    if (ENABLE_ERRORS) begin : g_status_logic
      assign status = {framing_error, overrun_error, break_condition};
    end else if (!ENABLE_ERRORS) begin : g_no_status
      // tie unused outputs to 0
      assign status = 0;
    end
  endgenerate

  localparam DIV_SAMPLE = 16,
           MID_SAMPLE = DIV_SAMPLE / 2,
           FRAME_LENGTH = (1 + DATA_BITS + 1) * DIV_SAMPLE;

  wire baud16_tick;

  uart_baud_gen #(
      .BAUD_RATE (BAUD_RATE),
      .CLK_FREQ  (CLK_FREQ),
      .OVERSAMPLE(DIV_SAMPLE)
  ) baud_gen (
      .clk(clk),
      .rst(rst),
      .baud_tick(baud16_tick)
  );

  typedef enum logic [2:0] {
    IDLE,
    START,
    DATA,
    STOP,
    ERROR
  } state_t;

  wire start_bit_detected;
  wire half_bit_elapsed;
  wire last_data_recieved;

  state_t state;
  reg [3:0] bit_counter;
  reg [3:0] sample_counter;

  reg framing_error;
  reg overrun_error;
  reg break_condition;
  reg [7:0] break_counter;

  assign start_bit_detected = !RsRx;
  assign half_bit_elapsed   = sample_counter == (MID_SAMPLE);
  assign last_data_recieved = bit_counter == (DATA_BITS);

  always @(posedge clk) begin
    if (rst) begin
      rx_data         <= 8'b0;
      valid_out       <= 0;
      bit_counter     <= 0;
      sample_counter  <= 0;
      framing_error   <= 0;
      overrun_error   <= 0;
      break_condition <= 0;
      break_counter   <= 0;
      state           <= IDLE;
    end else begin
      // Default: valid_out is a 1-cycle pulse
      valid_out <= 0;

      // --- Break Condition Logic ---
      if (baud16_tick) begin
        if (RsRx) begin
          break_counter   <= 0;
          break_condition <= 0;
        end else begin
          if (break_counter == FRAME_LENGTH) break_condition <= 1;
          else break_counter <= break_counter + 1;
        end
      end

      // --- Main FSM ---
      case (state)
        IDLE: begin
          if (baud16_tick) begin
            sample_counter <= 0;
            bit_counter    <= 0;
            if (start_bit_detected) begin
              state <= START;
            end
          end
        end

        START: begin
          if (baud16_tick) begin
            // Wait for the midpoint of the start bit to verify it's not a glitch
            if (sample_counter == DIV_SAMPLE - 1) begin
              sample_counter <= 0;
              state          <= DATA;
            end else begin
              sample_counter <= sample_counter + 1;
            end
          end
        end

        DATA: begin
          if (baud16_tick) begin
            if (sample_counter == FULL_BIT_TICKS - 1) begin
              sample_counter <= 0;
              rx_data[bit_counter] <= RsRx;  // Sample at the end/middle of bit period

              if (bit_counter == 7) begin
                state <= STOP;
              end else begin
                bit_counter <= bit_counter + 1;
              end
            end else begin
              sample_counter <= sample_counter + 1;
            end
          end
        end

        STOP: begin
          if (baud16_tick) begin
            if (sample_counter == FULL_BIT_TICKS - 1) begin
              sample_counter <= 0;
              // Validate Stop Bit (should be High)
              if (RsRx) begin
                valid_out <= 1;  // Success! Pulse valid_out
                state     <= IDLE;
              end else begin
                framing_error <= 1;
                state         <= IDLE;  // Or a dedicated error recovery state
              end
            end else begin
              sample_counter <= sample_counter + 1;
            end
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
