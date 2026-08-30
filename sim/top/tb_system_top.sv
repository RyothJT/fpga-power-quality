`timescale 1ns / 1ps

module tb_system_top;

  // -------------------------------------------------------------------------
  // Timing & Frequency Parameters
  // -------------------------------------------------------------------------
  parameter real SYSTEM_FREQ_HZ = 1_000_000.0;  // System clock frequency (5 MHz)
  parameter real CENTER_FREQ_HZ = 60.0;  // Grid nominal frequency (60 Hz)

  // Derived Clock Half-Period in nanoseconds
  localparam real CLK_PERIOD_NS = (1.0e9 / SYSTEM_FREQ_HZ);
  localparam real CLK_HALF_PERIOD_NS = CLK_PERIOD_NS / 2.0;

  // Derived Grid Fundamental Period in nanoseconds (~16.66 ms for 60 Hz)
  localparam real GRID_PERIOD_NS = (1.0e9 / CENTER_FREQ_HZ);

  // -------------------------------------------------------------------------
  // Signals & Registers
  // -------------------------------------------------------------------------
  logic         clk;
  logic         rst_n;

  // DDS Control Registers
  logic [15:-8] center_freq;
  logic [ 14:0] v_peak;
  logic [ 14:0] i_peak;
  logic         jitter_en;
  logic [  3:0] jitter_depth;
  logic [  7:0] current_phase;

  // Harmonic Control Registers
  logic [7:0] v_h3_scale, v_h5_scale, v_h7_scale;
  logic [7:0] i_h3_scale, i_h5_scale, i_h7_scale;

  // PLL Control Registers
  logic signed [ 15:0] k_sogi;
  logic signed [ 15:0] kp_pll;
  logic signed [ 15:0] ki_pll;

  // System Output Wires
  wire signed  [ 15:0] v_out;
  wire signed  [ 15:0] i_out;
  wire signed  [ 15:0] v_alpha;
  wire signed  [ 15:0] v_beta;
  wire signed  [ 15:0] v_d;
  wire signed  [ 15:0] v_q;
  wire         [ 15:0] theta;
  wire         [15:-8] freq_out;
  wire                 pll_locked;

  // -------------------------------------------------------------------------
  // Device Under Test (DUT)
  // -------------------------------------------------------------------------
  system_top #(
      .CLOCK_FREQ_HZ (SYSTEM_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) uut (
      .*
  );

  // Parameterized System Clock Generator
  always #(CLK_HALF_PERIOD_NS) clk = ~clk;

  // Conversion helper: Converts Hz to Q16.8 fixed-point format
  function automatic [15:-8] to_q16_8(input real freq_hz);
    begin
      to_q16_8 = 24'(integer'(freq_hz * 256.0));
    end
  endfunction

  // -------------------------------------------------------------------------
  // Main Verification Sequence
  // -------------------------------------------------------------------------
  initial begin
    // Initialize Clock & Reset
    clk           = 0;
    rst_n         = 0;

    // Default DDS Parameters
    center_freq   = to_q16_8(CENTER_FREQ_HZ);  // Nominal 60.0 Hz (24'd15360)
    v_peak        = 15'h3FFF;  // 100% Peak (Nominal ~16384)
    i_peak        = 15'h1FFF;  // ~25% Peak
    jitter_en     = 0;
    jitter_depth  = 4'd4;
    current_phase = 8'd32;  // ~45-degree lag

    v_h3_scale    = 8'd0;
    v_h5_scale    = 8'd0;
    v_h7_scale    = 8'd0;
    i_h3_scale    = 8'd0;
    i_h5_scale    = 8'd0;
    i_h7_scale    = 8'd0;

    // Standard SOGI and PI Control Loop Gains
    k_sogi        = 16'sd16384;  // K_sogi = 1.0 (Q1.14)
    kp_pll        = 16'sd120;  // Proportional Gain
    ki_pll        = 16'sd40;  // Integral Gain

    // Release Reset after 10 system clock cycles
    #(10.0 * CLK_PERIOD_NS);
    rst_n = 1;

    // -----------------------------------------------------------------------
    // Phase 1: Grid Lock Acquisition
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 1: Initializing PLL tracking on nominal 60.0 Hz grid...", $time);
    #(4.0 * GRID_PERIOD_NS);

    if (pll_locked) begin
      $display("[%0t ns] PLL successfully locked to nominal 60.0 Hz grid!", $time);
    end else begin
      $display("[%0t ns] WARNING: PLL failed to achieve lock in Phase 1.", $time);
    end

    // -----------------------------------------------------------------------
    // Phase 2: Frequency Step Tracking Test (+2.0 Hz Step)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 2: Stepping grid frequency to 62.0 Hz...", $time);
    center_freq = 24'd15872;  // 62.0 Hz in Q16.8 format (62.0 * 256)
    #(4.0 * GRID_PERIOD_NS);

    if (pll_locked) begin
      $display("[%0t ns] PLL successfully tracked frequency step to 62.0 Hz!", $time);
    end else begin
      $display("[%0t ns] WARNING: PLL failed to track frequency step.", $time);
    end

    // Reset back to 60.0 Hz nominal
    center_freq = 24'd15360;  // 60.0 Hz in Q16.8 format (60.0 * 256)

    // -----------------------------------------------------------------------
    // Phase 3: Voltage Sag / Amplitude Drop Test (50% Sag)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 3: Injecting 50%% voltage sag...", $time);
    v_peak = 15'd8192;  // Drop peak voltage magnitude by 50%
    #(4.0 * GRID_PERIOD_NS);

    // -----------------------------------------------------------------------
    // Phase 4: Harmonic Distortion Rejection Test
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 4: Injecting 3rd (15%%) and 5th (8%%) harmonics...", $time);
    v_h3_scale = 8'd38;  // ~15% 3rd harmonic
    v_h5_scale = 8'd20;  // ~8%  5th harmonic
    #(4.0 * GRID_PERIOD_NS);

    // -----------------------------------------------------------------------
    // Phase 5: Max Phase Jitter Noise Test
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 5: Enabling max clock/phase jitter...", $time);
    jitter_en    = 1'b1;
    jitter_depth = 4'd12;
    #(2.3 * GRID_PERIOD_NS);

    // -----------------------------------------------------------------------
    // Phase 6: Phase Jitter Noise Test
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 6: Enabling high clock/phase jitter...", $time);
    jitter_en    = 1'b1;
    jitter_depth = 4'd8;
    v_h3_scale = 8'd200;  // ~15% 3rd harmonic
    v_h5_scale = 8'd150;  // ~8%  5th harmonic
    #(6.0 * GRID_PERIOD_NS);

    $display("[%0t ns] System Verification Complete.", $time);
    $finish;
  end

  // -------------------------------------------------------------------------
  // Waveform Dump Configuration
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");

    // Top-Level Testbench Signals
    $dumpvars(1, tb_system_top.center_freq);
    $dumpvars(1, tb_system_top.clk);
    $dumpvars(1, tb_system_top.current_phase);
    $dumpvars(1, tb_system_top.freq_out);
    $dumpvars(1, tb_system_top.i_out);
    $dumpvars(1, tb_system_top.i_peak);
    $dumpvars(1, tb_system_top.jitter_depth);
    $dumpvars(1, tb_system_top.jitter_en);
    $dumpvars(1, tb_system_top.pll_locked);
    $dumpvars(1, tb_system_top.rst_n);
    $dumpvars(1, tb_system_top.v_alpha);
    $dumpvars(1, tb_system_top.v_beta);
    $dumpvars(1, tb_system_top.v_d);
    $dumpvars(1, tb_system_top.v_out);
    $dumpvars(1, tb_system_top.theta);
    $dumpvars(1, tb_system_top.v_peak);
    $dumpvars(1, tb_system_top.v_q);

    // Internal Sub-Module Signals (uut.u_pll hierarchy)
    $dumpvars(1, tb_system_top.uut.u_pll.pll_locked);
    $dumpvars(1, tb_system_top.uut.u_pll.v_alpha);
    $dumpvars(1, tb_system_top.uut.u_pll.v_beta);
    $dumpvars(1, tb_system_top.uut.u_pll.phase_inc);
    $dumpvars(1, tb_system_top.uut.u_pll.pi_out);
  end

endmodule
