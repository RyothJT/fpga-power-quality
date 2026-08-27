`timescale 1ns / 1ps

module tb_dds_top;

  reg         clk;
  reg         rst;
  reg         jitter_en;
  reg  [ 3:0] jitter_depth;
  reg  [ 8:0] sag_factor;
  reg  [ 7:0] current_phase;
  wire [15:0] v_out;
  wire [15:0] i_out;

  // Instantiate Top DDS Module
  dds_top uut (
      .clk(clk),
      .rst(rst),
      .jitter_en(jitter_en),
      .jitter_depth(jitter_depth),
      .sag_factor(sag_factor),
      .current_phase(current_phase),
      .v_out(v_out),
      .i_out(i_out)
  );

  // 100 MHz Clock Generation (10ns period)
  always #5 clk = ~clk;

  initial begin
    // Initialize Signals
    clk = 0;
    rst = 1;
    jitter_en = 0;
    jitter_depth = 4'd15;
    sag_factor = 9'd256;  // 100% nominal voltage
    current_phase = 8'd32;  // ~45 degree phase shift on Current (32/256 * 360)

    #100;
    rst = 0;

    // Run nominal grid output for 30 ms (covers ~1.8 grid cycles)
    #300_000;

    // Trigger a 50% Voltage Sag
    $display("[%0t ns] Injecting 50%% Voltage Sag...", $time);
    sag_factor = 8'd128;

    #200_000;

    // Recover Voltage and Inject Phase Jitter
    $display("[%0t ns] Recovering Voltage & Enabling Jitter...", $time);
    sag_factor = 8'd255;
    jitter_en  = 1;

    #300_000;

    $display("[%0t ns] Simulation Complete.", $time);
    $finish;
  end

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_dds_top);
  end

endmodule
