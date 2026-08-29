`timescale 1ns / 1ps

module tb_dds_top;

  reg         clk;
  reg         rst;
  reg  [23:0] center_freq;  // Frequency in Q16.8 format (e.g., 60.0 Hz = 24'd15360)
  reg  [14:0] v_peak;  // Primary wave peak amplitude scaling (Q0.15)
  reg  [14:0] i_peak;  // Primary wave peak amplitude scaling (Q0.15)
  reg         jitter_en;
  reg  [ 3:0] jitter_depth;
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

  // Instantiate Updated Top DDS Module
  dds_top #(
      .CLOCK_FREQ_HZ(100_000_000.0)
  ) uut (
      .clk(clk),
      .rst(rst),
      .center_freq(center_freq),
      .v_peak(v_peak),
      .i_peak(i_peak),
      .jitter_en(jitter_en),
      .jitter_depth(jitter_depth),
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

  function automatic [23:0] to_q16_8(input real freq_hz);
    begin
      to_q16_8 = 24'(integer'(freq_hz * 256.0));
    end
  endfunction

  initial begin
    // Initialize Signals
    clk           = 0;
    rst           = 1;
    center_freq   = to_q16_8(6000.0);  // Default 60.0 Hz (16'd15360)
    v_peak        = 16'h3FFF;  // Nominal full-scale voltage peak
    i_peak        = 16'd1000;
    jitter_en     = 0;
    jitter_depth  = 4'd12;
    current_phase = 8'd32;  // ~45 degree phase shift on Current (32/256 * 360)

    // Start with clean fundamental sine waves (0% harmonics)
    v_h3_scale    = 8'd0;
    v_h5_scale    = 8'd0;
    v_h7_scale    = 8'd0;

    i_h3_scale    = 8'd0;
    i_h5_scale    = 8'd0;
    i_h7_scale    = 8'd0;

    #100;
    rst = 0;

    // --- Phase 1: Pure Fundamental Waveforms @ 60 Hz ---
    $display("[%0t ns] Phase 1: Clean fundamental V and I @ 60.0 Hz...", $time);
    #3_000_000;

    // --- Phase 2: Frequency Sweep / Shift (Testing Q8.8 input) ---
    $display("[%0t ns] Phase 2: Shift center frequency to 50.0 Hz (European Grid)...", $time);
    center_freq = to_q16_8(5000.0);
    #3_000_000;

    $display("[%0t ns] Phase 2b: Shift center frequency to 400.0 Hz (Aerospace Grid)...", $time);
    center_freq = to_q16_8(40000.0);
    #100_000;

    // Return to 60 Hz nominal
    center_freq = to_q16_8(6000.0);

    // --- Phase 3: Heavy Current Harmonics & Amplitude Modulation (v_peak) ---
    $display("[%0t ns] Phase 3: Injecting harmonics and testing v_peak voltage drop (50%%)...",
             $time);
    v_peak     = 16'h1FFF;  // 50% Peak Amplitude
    v_h3_scale = 8'd8;  // Mild voltage distortion (~3%)
    v_h5_scale = 8'd5;  // (~2%)

    i_h3_scale = 8'd77;  // Severe current distortion (~30%)
    i_h5_scale = 8'd38;  // (~15%)
    i_h7_scale = 8'd20;  // (~8%)
    #3_000_000;

    // --- Phase 4: Over-amplitude Saturation Guard Verification ---
    $display(
        "[%0t ns] Phase 4: Testing over-amplitude v_peak with heavy harmonics to verify saturation clamping...",
        $time);
    v_peak     = 16'h7FFF;  // Push max peak headroom (~200%)
    v_h3_scale = 8'd128;  // Heavy 3rd harmonic
    v_h5_scale = 8'd64;  // Heavy 5th harmonic
    #3_000_000;

    // --- Phase 5: Recovery & Jitter Injection ---
    $display("[%0t ns] Phase 5: Recovering Nominal Peak & Enabling Jitter...", $time);
    v_peak     = 16'h3FFF;  // Back to 100% nominal
    v_h3_scale = 8'd0;
    v_h5_scale = 8'd0;
    jitter_en  = 1;
    #3_000_000;

    $display("[%0t ns] Simulation Complete.", $time);
    $finish;
  end

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_dds_top);
  end

endmodule
