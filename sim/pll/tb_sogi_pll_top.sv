`timescale 1us / 1ns

module tb_sogi_pll_top;

  // -------------------------------------------------------------------------
  // Primary Parameters
  // -------------------------------------------------------------------------
  localparam real SIM_CLK_FREQ_HZ = 100_000.0;  // Simulation clock frequency
  localparam real CENTER_FREQ_HZ = 60.0;  // Fundamental nominal grid frequency

  // -------------------------------------------------------------------------
  // Relative Frequency Variations (Derived off CENTER_FREQ_HZ)
  // -------------------------------------------------------------------------
  localparam real FREQ_HIGH_1_HZ = CENTER_FREQ_HZ * 1.0333;  // +3.33% (62 Hz)
  localparam real FREQ_LOW_HZ = CENTER_FREQ_HZ * 0.9667;  // -3.33% (58 Hz)
  localparam real FREQ_HIGH_2_HZ = CENTER_FREQ_HZ * 1.0833;  // +8.33% (65 Hz)

  // -------------------------------------------------------------------------
  // Derived Clock & Dynamic Delay Calculations
  // -------------------------------------------------------------------------
  localparam real SIM_CLK_PERIOD_US = (1.0 / SIM_CLK_FREQ_HZ) * 1_000_000.0;
  localparam real HALF_PERIOD_US = SIM_CLK_PERIOD_US / 2.0;

  localparam real LINE_PERIOD_US = (1.0 / CENTER_FREQ_HZ) * 1_000_000.0;
  localparam real LOCK_SETTLE_TIME = 18.0 * LINE_PERIOD_US;  // 18 line cycles
  localparam real TRANSIENT_TIME = 12.0 * LINE_PERIOD_US;  // 12 line cycles
  localparam real FINAL_SETTLE_TIME = 24.0 * LINE_PERIOD_US;  // 24 line cycles

  // Signals
  logic               clk;
  logic               rst_n;
  logic signed [15:0] v_in;

  // Gains & Outputs
  logic signed [15:0] k_sogi, kp_pll, ki_pll;
  logic signed [15:0] v_alpha, v_beta, v_d, v_q;
  logic        [ 15:0] theta;
  logic        [15:-8] freq_out;
  logic                pll_locked;

  // Testbench Control Variables
  real                 tb_phase = 0.0;
  real                 grid_freq = CENTER_FREQ_HZ;
  real                 grid_amplitude = 16383.0;
  int                  error_count = 0;

  // Track max v_q over dynamic checking window
  logic signed [ 15:0] max_vq_peak;

  // -------------------------------------------------------------------------
  // Device Under Test (DUT)
  // -------------------------------------------------------------------------
  sogi_pll_top #(
      .CLOCK_FREQ_HZ (SIM_CLK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) uut (
      .*
  );

  // Clock Generator derived from SIM_CLK_FREQ_HZ
  always #HALF_PERIOD_US clk = ~clk;

  // Monitor peak v_q magnitude
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      max_vq_peak <= '0;
    end else begin
      if ($abs($signed(v_q)) > max_vq_peak) begin
        max_vq_peak <= $abs($signed(v_q));
      end
    end
  end

  // -------------------------------------------------------------------------
  // Self-Checking Verification Tasks
  // -------------------------------------------------------------------------

  // 1. Expected Locked Check
  task automatic check_pll(input string step_name, input real expected_freq_hz,
                           input real freq_tolerance_hz = 0.5, input int vq_max_threshold = 400);
    real measured_freq;

    max_vq_peak = 0;
    #(LINE_PERIOD_US);

    measured_freq = $itor(freq_out) / 256.0;

    $display("\n[CHECK] Running Validation: %s", step_name);

    if (!pll_locked) begin
      $display("[FAIL] %s: PLL failed to lock! pll_locked = %0b", step_name, pll_locked);
      error_count++;
    end else begin
      $display("[PASS] %s: PLL Locked successfully.", step_name);
    end

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

    if (max_vq_peak > vq_max_threshold) begin
      $display("[FAIL] %s: Quadrature voltage peak error high! Peak v_q = %0d (Limit: %0d)",
               step_name, max_vq_peak, vq_max_threshold);
      error_count++;
    end else begin
      $display("[PASS] %s: Peak quadrature error |v_q| = %0d (within limit %0d)", step_name,
               max_vq_peak, vq_max_threshold);
    end
  endtask

  // 2. Expected Unlocked Check (Grid Loss / Fault Test)
  task automatic check_pll_unlock(input string step_name, input int vq_min_unlock_thresh = 800);
    max_vq_peak = 0;
    #(LINE_PERIOD_US * 2);

    $display("\n[CHECK] Running Validation (Unlock Expected): %s", step_name);

    if (pll_locked) begin
      $display("[FAIL] %s: PLL remained locked during severe grid fault! pll_locked = %0b",
               step_name, pll_locked);
      error_count++;
    end else begin
      $display("[PASS] %s: PLL unlocked as expected (pll_locked = 0).", step_name);
    end

    if (max_vq_peak < vq_min_unlock_thresh) begin
      $display(
          "[WARN] %s: Quadrature voltage peak v_q = %0d below unlock hysteresis boundary (%0d)",
          step_name, max_vq_peak, vq_min_unlock_thresh);
    end else begin
      $display("[PASS] %s: Quadrature error peak |v_q| = %0d exceeded unlock boundary.", step_name,
               max_vq_peak);
    end
  endtask

  // -------------------------------------------------------------------------
  // Main Stimulus Procedure
  // -------------------------------------------------------------------------
  initial begin
    clk = 0;
    rst_n = 0;
    v_in = 0;

    // SOGI Damping Factor k = 1.414 (in Q1.14)
    k_sogi = 16'sd16384;
    kp_pll = 16'sd120;
    ki_pll = 16'sd40;

    #(SIM_CLK_PERIOD_US * 10);
    rst_n = 1;

    // 1. Initial Nominal Lock Phase
    #(LOCK_SETTLE_TIME);
    check_pll("1. Initial Lock Phase", CENTER_FREQ_HZ);

    // 2. Inject a 90-degree Phase Step
    $display("\n[TB] --- Injecting 90-degree Phase Step into v_in ---");
    @(posedge clk);
    tb_phase = tb_phase + 1.57079632679;
    #(TRANSIENT_TIME);
    check_pll("2. Post 90-deg Phase Step Settle", CENTER_FREQ_HZ);

    // 3. Inject Frequency Jump (+3.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_HIGH_1_HZ);
    grid_freq = FREQ_HIGH_1_HZ;
    #(LOCK_SETTLE_TIME);
    check_pll("3. Frequency Jump +3.33%", FREQ_HIGH_1_HZ);

    // 4. Inject Voltage Sag (80%)
    $display("\n[TB] --- Injecting Voltage Sag of 80%% ---");
    grid_amplitude = grid_amplitude * 0.8;
    #(TRANSIENT_TIME);
    check_pll("4. Voltage Sag (80%)", FREQ_HIGH_1_HZ);
    grid_amplitude = 16383.0;

    // 5. Inject Frequency Jump (-3.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_LOW_HZ);
    grid_freq = FREQ_LOW_HZ;
    #(LOCK_SETTLE_TIME);
    check_pll("5. Frequency Jump -3.33%", FREQ_LOW_HZ);

    // 6. Inject Frequency Jump (+8.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_HIGH_2_HZ);
    grid_freq = FREQ_HIGH_2_HZ;
    #(LOCK_SETTLE_TIME);
    check_pll("6. Frequency Jump +8.33%", FREQ_HIGH_2_HZ);

    // 7. Return to Nominal Frequency
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             CENTER_FREQ_HZ);
    grid_freq = CENTER_FREQ_HZ;
    #(FINAL_SETTLE_TIME);
    check_pll("7. Return to Nominal Frequency", CENTER_FREQ_HZ);

    // 8. Grid Loss / Total Voltage Collapse (SHOULD UNLOCK)
    $display("\n[TB] --- Injecting Complete Grid Loss (v_in = 0) ---");
    grid_amplitude = 0.0;
    #(TRANSIENT_TIME);
    check_pll_unlock("8. Grid Loss / Total Voltage Collapse");

    // 9. Recover Grid Voltage (SHOULD RE-LOCK)
    $display("\n[TB] --- Restoring Grid Voltage to Nominal ---");
    grid_amplitude = 16383.0;
    #(LOCK_SETTLE_TIME);
    check_pll("9. Recovery Post Grid Outage", CENTER_FREQ_HZ);

    // -------------------------------------------------------------------------
    // Self-Testing Summary & Reporting
    // -------------------------------------------------------------------------
    $display("\n==================================================");
    if (error_count == 0) begin
      $display("    TEST PASSED: ALL SOGI-PLL CHECKS SUCCESSFUL   ");
    end else begin
      $display("    TEST FAILED: %0d ERRORS ENCOUNTERED           ", error_count);
    end
    $display("==================================================\n");

    $finish;
  end

  // Phase increment per clock tick parameterized by SIM_CLK_FREQ_HZ
  always @(posedge clk) begin
    if (rst_n) begin
      tb_phase = tb_phase + (2.0 * 3.141592653589793 * grid_freq / SIM_CLK_FREQ_HZ);
      if (tb_phase >= (2.0 * 3.141592653589793)) begin
        tb_phase = tb_phase - (2.0 * 3.141592653589793);
      end
      v_in = $rtoi(grid_amplitude * $sin(tb_phase));
    end
  end

  // -------------------------------------------------------------------------
  // Simulation Debug Monitor
  // -------------------------------------------------------------------------
  logic [15:0] theta_prev;
  logic [63:0] last_time;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      theta_prev <= '0;
      last_time  <= '0;
    end else begin
      theta_prev <= theta;
      if (theta_prev > 16'd50000 && theta < 16'd5000) begin
        $display("[TB] Rollover | Period = %0d us | freq_out: %0.2f Hz", $time - last_time, $itor
                 (freq_out) / 256.0);
        last_time <= $time;
      end
    end
  end

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_sogi_pll_top);
  end

endmodule
