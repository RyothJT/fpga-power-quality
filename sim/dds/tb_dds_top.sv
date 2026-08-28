`timescale 1ns / 1ps

module tb_dds_top;

  reg         clk;
  reg         rst;
  reg         jitter_en;
  reg  [ 3:0] jitter_depth;
  reg  [ 7:0] sag_factor;
  reg  [ 7:0] current_phase;

  // Voltage Harmonic Amplitude Controls
  reg  [ 7:0] v_h3_scale;
  reg  [ 7:0] v_h5_scale;
  reg  [ 7:0] v_h7_scale;

  // Current Harmonic Amplitude Controls
  reg  [ 7:0] i_h3_scale;
  reg  [ 7:0] i_h5_scale;
  reg  [ 7:0] i_h7_scale;

  wire [15:0] v_out;
  wire [15:0] i_out;

  // Instantiate Top DDS Module with Dual Harmonic Controls
  dds_top uut (
      .clk(clk),
      .rst(rst),
      .jitter_en(jitter_en),
      .jitter_depth(jitter_depth),
      .sag_factor(sag_factor),
      .current_phase(current_phase),
      .v_h3_scale(v_h3_scale),
      .v_h5_scale(v_h5_scale),
      .v_h7_scale(v_h7_scale),
      .i_h3_scale(i_h3_scale),
      .i_h5_scale(i_h5_scale),
      .i_h7_scale(i_h7_scale),
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
    jitter_depth = 4'd12;
    sag_factor = 8'd128;  // Nominal voltage (100%)
                          // range from 0-255, with 255 representing ~200% normal voltage.
    current_phase = 8'd32;  // ~45 degree phase shift on Current (32/256 * 360)

    // Start with clean fundamental sine waves (0% harmonics)
    v_h3_scale = 8'd0;
    v_h5_scale = 8'd0;
    v_h7_scale = 8'd0;

    i_h3_scale = 8'd0;
    i_h5_scale = 8'd0;
    i_h7_scale = 8'd0;

    #100;
    rst = 0;

    // --- Phase 1: Pure Fundamental Waveforms ---
    $display("[%0t ns] Phase 1: Clean fundamental V and I waveforms...", $time);
    #300_000;

    // --- Phase 2: Heavy Current Harmonics (Typical Non-Linear Load) ---
    $display("[%0t ns] Phase 2: Injecting high current harmonics (30%% 3rd, 15%% 5th, 8%% 7th)...",
             $time);
    v_h3_scale = 8'd8;  // Mild voltage distortion (~3%)
    v_h5_scale = 8'd5;  // (~2%)
    v_h7_scale = 8'd0;

    i_h3_scale = 8'd77;  // Severe current distortion (~30%)
    i_h5_scale = 8'd38;  // (~15%)
    i_h7_scale = 8'd20;  // (~8%)
    #300_000;

    // --- Phase 3: Voltage Sag Under Heavy Harmonic Load ---
    $display("[%0t ns] Phase 3: Injecting 50%% Voltage Sag under harmonic load...", $time);
    sag_factor = 8'd64;  // 50% scale
    v_h7_scale = 8'd128;
    #300_000;

    // --- Phase 4: Recovery & Jitter Injection ---
    $display("[%0t ns] Phase 4: Recovering Voltage & Enabling Jitter...", $time);
    sag_factor = 8'd128;  // 100% scale
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
