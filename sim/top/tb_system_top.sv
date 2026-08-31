`timescale 1ns / 1ps

module tb_system_top;

  // -------------------------------------------------------------------------
  // Timing & Frequency Parameters
  // -------------------------------------------------------------------------
  localparam real SYSTEM_FREQ_HZ = 1_000_000.0;  // System clock frequency (1 MHz)
  localparam real CENTER_FREQ_HZ = 60.0;  // Grid nominal frequency (60 Hz)

  // Derived Clock Half-Period in nanoseconds
  localparam real CLK_PERIOD_NS = (1.0e9 / SYSTEM_FREQ_HZ);
  localparam real CLK_HALF_PERIOD_NS = CLK_PERIOD_NS / 2.0;

  // Derived Grid Fundamental Period in nanoseconds (~16.66 ms for 60 Hz)
  localparam real GRID_PERIOD_NS = (1.0e9 / CENTER_FREQ_HZ);

  // Settling durations parameterized by line period
  localparam real LOCK_SETTLE_TIME = 18.0 * GRID_PERIOD_NS;  // 18 line cycles
  localparam real TRANSIENT_TIME = 12.0 * GRID_PERIOD_NS;  // 12 line cycles
  localparam real FINAL_SETTLE_TIME = 24.0 * GRID_PERIOD_NS;  // 24 line cycles

  // -------------------------------------------------------------------------
  // Signals & Registers
  // -------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;

  // DDS Control Registers
  logic [23:0] center_freq;
  logic [ 4:0] bit_precision;
  logic [14:0] v_peak;
  logic [14:0] i_peak;
  logic        jitter_en;
  logic [ 3:0] jitter_depth;
  logic [ 7:0] current_phase;

  // Harmonic Control Registers
  logic [7:0] v_h3_scale, v_h5_scale, v_h7_scale;
  logic [7:0] i_h3_scale, i_h5_scale, i_h7_scale;

  // PLL Control Registers
  logic signed [ 15:0] k_sogi;
  logic signed [ 15:0] kp_pll;
  logic signed [ 15:0] ki_pll;

  // System Waveform Outputs
  wire signed  [ 15:0] v_out;
  wire signed  [ 15:0] i_out;

  // SOGI-PLL Telemetry Outputs
  wire signed  [ 15:0] v_alpha;
  wire signed  [ 15:0] v_beta;
  wire signed  [ 15:0] v_d;
  wire signed  [ 15:0] v_q;
  wire         [ 15:0] theta;
  wire         [15:-8] freq_out;
  wire                 pll_locked;

  // Current QSG Telemetry Outputs
  wire signed  [ 15:0] i_alpha;
  wire signed  [ 15:0] i_beta;

  // Power Engine Telemetry Outputs
  wire signed  [ 15:0] p_inst;
  wire signed  [ 15:0] q_inst;
  wire signed  [ 15:0] p_avg;
  wire signed  [ 15:0] q_avg;
  wire         [ 15:0] v_rms;
  wire         [ 15:0] i_rms;

  // Self-Checking Verification Variables
  int                  error_count = 0;
  logic signed [ 15:0] max_vq_peak;

  // -------------------------------------------------------------------------
  // Device Under Test (DUT)
  // -------------------------------------------------------------------------
  system_top #(
      .CLOCK_FREQ_HZ (SYSTEM_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) uut (
      .clk          (clk),
      .rst_n        (rst_n),
      .center_freq  (center_freq),
      .bit_precision(bit_precision),
      .v_peak       (v_peak),
      .i_peak       (i_peak),
      .jitter_en    (jitter_en),
      .jitter_depth (jitter_depth),
      .current_phase(current_phase),
      .v_h3_scale   (v_h3_scale),
      .v_h5_scale   (v_h5_scale),
      .v_h7_scale   (v_h7_scale),
      .i_h3_scale   (i_h3_scale),
      .i_h5_scale   (i_h5_scale),
      .i_h7_scale   (i_h7_scale),
      .k_sogi       (k_sogi),
      .kp_pll       (kp_pll),
      .ki_pll       (ki_pll),
      .v_out        (v_out),
      .i_out        (i_out),
      .v_alpha      (v_alpha),
      .v_beta       (v_beta),
      .v_d          (v_d),
      .v_q          (v_q),
      .theta        (theta),
      .freq_out     (freq_out),
      .pll_locked   (pll_locked),
      .i_alpha      (i_alpha),
      .i_beta       (i_beta),
      .p_inst       (p_inst),
      .q_inst       (q_inst),
      .p_avg        (p_avg),
      .q_avg        (q_avg),
      .v_rms        (v_rms),
      .i_rms        (i_rms)
  );

  // Parameterized System Clock Generator
  always #(CLK_HALF_PERIOD_NS) clk = ~clk;

  // Continuous Peak Magnitude Tracker for Phase Error (v_q)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      max_vq_peak <= '0;
    end else begin
      if ($abs($signed(v_q)) > max_vq_peak) begin
        max_vq_peak <= $abs($signed(v_q));
      end
    end
  end

  // Conversion helper: Converts Hz to Q16.8 fixed-point format
  function automatic [23:0] to_q16_8(input real freq_hz);
    begin
      to_q16_8 = 24'(integer'(freq_hz * 256.0));
    end
  endfunction

  // -------------------------------------------------------------------------
  // Self-Checking Verification Task
  // -------------------------------------------------------------------------
  task automatic check_system(input string step_name, input real expected_freq_hz,
                              input real freq_tolerance_hz = 0.5, input int vq_max_threshold = 400,
                              input bit check_power = 1'b1);
    real measured_freq;

    // Reset peak measurement window and observe over 1 line cycle
    max_vq_peak = 0;
    #(GRID_PERIOD_NS);

    measured_freq = $itor(freq_out) / 256.0;

    $display("\n[CHECK] Running Validation: %s", step_name);

    // 1. Validate Lock Status
    if (!pll_locked) begin
      $display("[FAIL] %s: PLL failed to lock! pll_locked = %0b", step_name, pll_locked);
      error_count++;
    end else begin
      $display("[PASS] %s: PLL Locked successfully.", step_name);
    end

    // 2. Validate Frequency Tracking (Q16.8)
    if ((measured_freq < (expected_freq_hz - freq_tolerance_hz)) ||
        (measured_freq > (expected_freq_hz + freq_tolerance_hz))) begin
      $display(
          "[FAIL] %s: Frequency mismatch! Expected: %0.2f Hz, Measured: %0.2f Hz (Tolerance: +/- %0.2f Hz)",
          step_name, expected_freq_hz, measured_freq, freq_tolerance_hz);
      error_count++;
    end else begin
      $display("[PASS] %s: Measured Frequency = %0.2f Hz (Expected: %0.2f Hz)", step_name,
               measured_freq, expected_freq_hz);
    end

    // 3. Validate Quadrature Voltage Error (v_q residual)
    if (max_vq_peak > vq_max_threshold) begin
      $display("[FAIL] %s: Peak quadrature phase error high! Peak |v_q| = %0d (Limit: %0d)",
             step_name, max_vq_peak, vq_max_threshold);
      error_count++;
    end else begin
      $display("[PASS] %s: Peak quadrature error |v_q| = %0d (within limit %0d)", step_name,
               max_vq_peak, vq_max_threshold);
    end

    // 4. Validate Power & RMS Engine Metrics
    if (check_power) begin
      if (v_rms == 0 || i_rms == 0) begin
        $display("[FAIL] %s: Power Engine RMS values unpopulated! v_rms = %0d, i_rms = %0d",
               step_name, v_rms, i_rms);
        error_count++;
      end else begin
        $display(
            "[PASS] %s: Power Engine telemetry verified (v_rms = %0d, i_rms = %0d, P_avg = %0d, Q_avg = %0d)",
            step_name, v_rms, i_rms, p_avg, q_avg);
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Main Verification Sequence
  // -------------------------------------------------------------------------
  initial begin
    // Initialize Clock & Reset
    clk           = 0;
    rst_n         = 0;

    // Default DDS Parameters
    center_freq   = to_q16_8(CENTER_FREQ_HZ);  // 60.0 Hz (24'd15360)
    bit_precision = 5'd12;
    v_peak        = 15'h3FFF;  // 100% Peak (~16383)
    i_peak        = 15'h1FFF;  // ~50% Peak (~8191)
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
    // k_sogi        = 16'sd16384;  // K_sogi = 1.0 (Q1.14)
    k_sogi        = 16'sd8192;  // K_sogi = 0.5 (Q1.14)
    kp_pll        = 16'sd120;  // Proportional Gain
    ki_pll        = 16'sd40;  // Integral Gain

    // Release Reset after 10 system clock cycles
    #(10.0 * CLK_PERIOD_NS);
    rst_n = 1;

    // -----------------------------------------------------------------------
    // Phase 1: Grid Lock Acquisition
    // -----------------------------------------------------------------------
    $display("[%0t ns] Phase 1: Initializing PLL tracking on nominal 60.0 Hz grid...", $time);
    #(LOCK_SETTLE_TIME);
    check_system("Phase 1: Initial Grid Lock", 60.0);

    // -----------------------------------------------------------------------
    // Phase 2: Frequency Step Tracking Test (+2.0 Hz Step)
    // -----------------------------------------------------------------------
    $display("\n[%0t ns] Phase 2: Stepping grid frequency to 62.0 Hz...", $time);
    center_freq = to_q16_8(62.0);  // 62.0 Hz in Q16.8 format (24'd15872)
    #(LOCK_SETTLE_TIME);
    check_system("Phase 2: Frequency Step (+2.0 Hz)", 62.0);

    // Reset back to nominal 60.0 Hz
    center_freq = to_q16_8(CENTER_FREQ_HZ);

    // -----------------------------------------------------------------------
    // Phase 3: Voltage Sag / Amplitude Drop Test (50% Sag)
    // -----------------------------------------------------------------------
    $display("\n[%0t ns] Phase 3: Injecting 50%% voltage sag...", $time);
    v_peak = 15'd8192;  // Drop peak voltage magnitude by 50%
    #(TRANSIENT_TIME);
    check_system("Phase 3: Voltage Sag (50%)", 60.0);
    v_peak = 15'h3FFF;  // Restore amplitude

    // -----------------------------------------------------------------------
    // Phase 4: Harmonic Distortion Rejection Test
    // -----------------------------------------------------------------------
    $display("\n[%0t ns] Phase 4: Injecting 3rd (15%%) and 5th (8%%) harmonics...", $time);
    v_h3_scale = 8'd38;  // ~15% 3rd harmonic
    v_h5_scale = 8'd20;  // ~8%  5th harmonic
    #(TRANSIENT_TIME);
    check_system("Phase 4: Harmonic Injection Rejection", 60.0, 0.8, 600);
    v_h3_scale = 8'd0;
    v_h5_scale = 8'd0;

    // -----------------------------------------------------------------------
    // Phase 5: Phase Jitter Noise Test
    // -----------------------------------------------------------------------
    $display("\n[%0t ns] Phase 5: Enabling high phase jitter & heavy harmonics...", $time);
    jitter_en    = 1'b1;
    jitter_depth = 4'd8;
    v_h3_scale   = 8'd38;
    v_h5_scale   = 8'd20;
    #(FINAL_SETTLE_TIME);
    check_system("Phase 5: Max Phase Jitter & Harmonics", 60.0, 1.2, 800);

    // -----------------------------------------------------------------------
    // Verification Summary & Completion
    // -----------------------------------------------------------------------
    $display("\n==================================================");
    if (error_count == 0) begin
      $display("    TEST PASSED: ALL SYSTEM CHECKS SUCCESSFUL     ");
    end else begin
      $display("    TEST FAILED: %0d ERRORS ENCOUNTERED           ", error_count);
    end
    $display("==================================================\n");

    $finish;
  end

  // -------------------------------------------------------------------------
  // Waveform Dump Configuration
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_system_top);
  end

endmodule
