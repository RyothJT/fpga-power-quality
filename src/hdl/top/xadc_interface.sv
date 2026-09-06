`timescale 1ns / 1ps

module xadc_interface (
    input  logic               clk_100m,
    input  logic               reset_n,
    input  logic               v_p,
    v_n,
    input  logic               i_p,
    i_n,
    output logic signed [15:0] v_data_o,
    output logic signed [15:0] i_data_o,
    output logic               data_valid_o,
    output logic        [11:0] raw_v_debug,
    output logic        [11:0] raw_i_debug,   // Added for I-path verification
    output logic               activity_led
);

  logic [15:0] do_out;
  logic [ 4:0] channel_out;
  logic drdy_out, eoc_out, eos_out;

  XADC #(
      .INIT_40(16'h0000),
      .INIT_41(16'h2100),
      .INIT_42(16'h0400),
      // .INIT_48(16'h0040),  // SEQ 0: VAUX6 (Voltage)
      .INIT_49(16'h4040),  // SEQ 1: VAUX14 (Current)
      .SIM_DEVICE("7SERIES")
  ) raw_xadc_inst (
      .DADDR({2'b0, channel_out}),
      .DCLK(clk_100m),
      .DEN(eoc_out || eos_out),
      .DI(16'h0),
      .DWE(1'b0),
      .RESET(!reset_n),
      .DO(do_out),
      .DRDY(drdy_out),
      .VAUXP({1'b0, i_p, 7'b0, v_p, 6'b0}),
      .VAUXN({1'b0, i_n, 7'b0, v_n, 6'b0}),
      .VP(1'b0),
      .VN(1'b0),
      .EOC(eoc_out),
      .EOS(eos_out),
      .CHANNEL(channel_out),
      .BUSY(),
      .ALM(),
      .OT(),
      .MUXADDR()
  );

  always_ff @(posedge clk_100m) if (drdy_out) activity_led <= ~activity_led;

  logic [5:0] dec_cnt;
  always_ff @(posedge clk_100m or negedge reset_n) begin
    if (!reset_n) begin
      v_data_o <= 0;
      i_data_o <= 0;
      data_valid_o <= 0;
      raw_v_debug <= 0;
      raw_i_debug <= 0;
      dec_cnt <= 0;
    end else begin
      data_valid_o <= 1'b0;
      if (drdy_out) begin
        if (channel_out == 5'h16) begin  // Voltage
          v_data_o    <= do_out - 16'h8000;
          raw_v_debug <= do_out[15:4];
        end else if (channel_out == 5'h1E) begin  // Current
          i_data_o    <= do_out - 16'h8000;
          raw_i_debug <= do_out[15:4];
          // Pulse every ~20kHz
          if (dec_cnt >= 47) begin
            dec_cnt <= 0;
            data_valid_o <= 1'b1;
          end else dec_cnt <= dec_cnt + 1;
        end
      end
    end
  end
endmodule
