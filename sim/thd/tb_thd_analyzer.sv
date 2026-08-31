`timescale 1ns / 1ps

module tb_thd_analyzer;

  // -------------------------------------------------------------------------
  // Timing & Frequency Parameters
  // -------------------------------------------------------------------------
  localparam real CLOCK_FREQ_HZ = 100_000.0;  // 100 MHz
  localparam real GRID_FREQ_HZ = 60.0;
  localparam real CUTOFF_FREQ_HZ = 10.0;

  // Calculate periods
  localparam real CLK_PERIOD_NS = 1_000_000_000.0 / CLOCK_FREQ_HZ;
  localparam real GRID_PERIOD_NS = 1_000_000_000.0 / GRID_FREQ_HZ;

  // Settling Time: We need ~5 time constants. Tau = 2^K clock cycles.
  // We wait for a specific number of Grid Cycles to ensure visibility in waveforms.
  localparam int SETTLING_CYCLES = 10;

  // -------------------------------------------------------------------------
  // Signals
  // -------------------------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  logic signed [15:0] v_in;
  logic signed [15:0] v_alpha, v_beta;
  logic        pll_locked;
  logic [3:-12] thd_val;

  // Math variables for stimulus
  real         phase_acc = 0.0;
  real         phase_inc = (2.0 * 3.1415926535 * GRID_FREQ_HZ) / CLOCK_FREQ_HZ;
  real         amp_fund = 20000.0;
  real         amp_harm = 0.0;

  // -------------------------------------------------------------------------
  // Component Instantiation
  // -------------------------------------------------------------------------
  thd_analyzer #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CUTOFF_FREQ_HZ(CUTOFF_FREQ_HZ)
  ) uut (
      .clk       (clk),
      .rst_n     (rst_n),
      .v_in      (v_in),
      .v_alpha   (v_alpha),
      .v_beta    (v_beta),
      .pll_locked(pll_locked),
      .thd_val   (thd_val)
  );

  // -------------------------------------------------------------------------
  // Clock & Signal Generation
  // -------------------------------------------------------------------------
  always #(CLK_PERIOD_NS / 2) clk = ~clk;

  // Use 'always' (not always_ff) for simulation-only real math
  always @(posedge clk) begin
    if (!rst_n) begin
      phase_acc <= 0.0;
      v_in      <= '0;
      v_alpha   <= '0;
      v_beta    <= '0;
    end else begin
      phase_acc <= phase_acc + phase_inc;
      v_in      <= 16'($rtoi(amp_fund * $sin(phase_acc) + amp_harm * $sin(3.0 * phase_acc)));
      v_alpha   <= 16'($rtoi(amp_fund * $sin(phase_acc)));
      v_beta    <= 16'($rtoi(amp_fund * $cos(phase_acc)));
    end
  end

  // -------------------------------------------------------------------------
  // Test Logic
  // -------------------------------------------------------------------------
  initial begin
    $display("[%0t ns] Starting THD Analyzer Verification...", $time);

    // Initial State
    rst_n = 0;
    pll_locked = 0;
    amp_harm = 0.0;

    #(GRID_PERIOD_NS * 2);
    rst_n = 1;
    #(GRID_PERIOD_NS * 1);
    pll_locked = 1;

    // --- Phase 1: Pure Sine (0% THD) ---
    run_test_case(0.00, "Clean Fundamental");

    // --- Phase 2: 5% THD (Standard Limit) ---
    run_test_case(0.05, "5% 3rd Harmonic Injection");

    // --- Phase 3: 15% THD (High Distortion) ---
    run_test_case(0.15, "15% Harmonic Stress Test");

    // --- Phase 4: Harmonics Removed (Return to Clean) ---
    run_test_case(0.00, "Distortion Removal / Recovery");

    $display("[%0t ns] All tests complete.", $time);
    $finish;
  end

  // -------------------------------------------------------------------------
  // Task: run_test_case
  // -------------------------------------------------------------------------
  task run_test_case(input real target_pct, input string desc);
    real expected_q12;
    real measured_pct;
    begin
      $display("[%0t ns] PHASE START: %s (Target: %0.2f%%)", $time, desc, target_pct * 100.0);
      amp_harm = amp_fund * target_pct;

      // Wait for the calculated settling time (Multiple grid cycles)
      #(GRID_PERIOD_NS * SETTLING_CYCLES);

      expected_q12 = target_pct * 4096.0;
      measured_pct = (real'(thd_val) / 4096.0) * 100.0;

      $display("[%0t ns] Result: Measured %0.2f%% (Raw: %0d), Expected %0.2f%%", $time,
               measured_pct, thd_val, target_pct * 100.0);

      // Self-checking logic (1% absolute tolerance)
      if (abs_diff(real'(thd_val), expected_q12) > 41.0) begin
        $display("ERROR: THD out of tolerance in '%s'!", desc);
      end
    end
  endtask

  function real abs_diff(input real a, input real b);
    abs_diff = (a > b) ? (a - b) : (b - a);
  endfunction

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_thd_analyzer);
  end

endmodule
