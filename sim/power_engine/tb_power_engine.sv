`timescale 1ns / 1ps

module tb_power_engine;

  localparam real CLOCK_FREQ_HZ = 1_000_000.0;
  localparam real CENTER_FREQ_HZ = 60.0;
  localparam real CLK_PERIOD_NS = 1_000_000_000.0 / CLOCK_FREQ_HZ;
  localparam real GRID_PERIOD_NS = 1_000_000_000.0 / CENTER_FREQ_HZ;

  localparam signed [15:0] PEAK_AMPLITUDE = 16'sd16384;
  localparam logic [15:0] EXPECTED_RMS = 16'd11585;

  logic clk;
  logic rst_n;

  logic signed [15:0] v_alpha, v_beta, i_alpha, i_beta;
  logic signed [15:0] p_inst, q_inst, p_avg, q_avg;
  logic [15:0] v_rms, i_rms;

  int  error_count = 0;
  real phase_rad = 0.0;
  real phase_step = (2.0 * 3.141592653589793) * (CENTER_FREQ_HZ / CLOCK_FREQ_HZ);
  real current_phase_shift = 0.0;
  real v_amplitude_scale = 1.0;
  real i_amplitude_scale = 1.0;

  initial clk = 1'b0;
  always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

  // Standard always block for floating-point stimulus updates
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase_rad <= 0.0;
      v_alpha   <= '0;
      v_beta    <= '0;
      i_alpha   <= '0;
      i_beta    <= '0;
    end else begin
      phase_rad <= phase_rad + phase_step;

      v_alpha <= 16'($rtoi(PEAK_AMPLITUDE * v_amplitude_scale * $cos(phase_rad)));
      v_beta <= 16'($rtoi(PEAK_AMPLITUDE * v_amplitude_scale * $sin(phase_rad)));

      i_alpha <= 16'($rtoi(
          PEAK_AMPLITUDE * i_amplitude_scale * $cos(phase_rad - current_phase_shift)
      ));
      i_beta <= 16'($rtoi(
          PEAK_AMPLITUDE * i_amplitude_scale * $sin(phase_rad - current_phase_shift)
      ));
    end
  end

  power_engine #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) dut (
      .clk    (clk),
      .rst_n  (rst_n),
      .v_alpha(v_alpha),
      .v_beta (v_beta),
      .i_alpha(i_alpha),
      .i_beta (i_beta),
      .p_inst (p_inst),
      .q_inst (q_inst),
      .p_avg  (p_avg),
      .q_avg  (q_avg),
      .v_rms  (v_rms),
      .i_rms  (i_rms)
  );

  initial begin
    $display("\n==================================================");
    $display(" Starting Self-Checking Testbench: power_engine");
    $display("==================================================");

    rst_n = 1'b0;
    current_phase_shift = 0.0;
    v_amplitude_scale = 1.0;
    i_amplitude_scale = 1.0;

    #(10.0 * CLK_PERIOD_NS);
    rst_n = 1'b1;

    // -----------------------------------------------------------------------
    // Test Case 1: Unity Power Factor (In-Phase V & I, PF = 1.0)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 1: In-Phase Signals (Unity Power Factor, PF = 1.0)", $time);
    #(12.0 * GRID_PERIOD_NS);
    check_signed("P_AVG (PF=1.0)", p_avg, 16'sd4096, 16'sd400);
    check_signed("Q_AVG (PF=1.0)", q_avg, 16'sd0, 16'sd400);
    check_unsigned("V_RMS", v_rms, EXPECTED_RMS, 16'd300);
    check_unsigned("I_RMS", i_rms, EXPECTED_RMS, 16'd300);

    // -----------------------------------------------------------------------
    // Test Case 2: 90 Degree Lagging Current (Pure Inductive, PF = 0.0)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 2: 90 Deg Lagging Current (Pure Inductive, PF = 0.0)", $time);
    current_phase_shift = 3.141592653589793 / 2.0;  // +90 deg
    #(12.0 * GRID_PERIOD_NS);
    check_signed("P_AVG (PF=0.0)", p_avg, 16'sd0, 16'sd400);
    check_signed("Q_AVG (PF=0.0)", q_avg, 16'sd8192, 16'sd400);
    check_unsigned("V_RMS", v_rms, EXPECTED_RMS, 16'd300);
    check_unsigned("I_RMS", i_rms, EXPECTED_RMS, 16'd300);

    // -----------------------------------------------------------------------
    // Test Case 3: 45 Degree Lagging Current (Inductive Load, PF = 0.707)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 3: 45 Deg Lagging Current (PF = 0.707)", $time);
    current_phase_shift = 3.141592653589793 / 4.0;  // +45 deg
    #(12.0 * GRID_PERIOD_NS);
    check_signed("P_AVG (PF=0.707)", p_avg, 16'sd2896, 16'sd400);
    check_signed("Q_AVG (PF=0.707)", q_avg, 16'sd5793, 16'sd400);

    // -----------------------------------------------------------------------
    // Test Case 4: 180 Degree Out-of-Phase (Reverse Power Flow, PF = -1.0)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 4: 180 Deg Out-of-Phase (Reverse Power, PF = -1.0)", $time);
    current_phase_shift = 3.141592653589793;  // 180 deg
    #(12.0 * GRID_PERIOD_NS);
    check_signed("P_AVG (PF=-1.0)", p_avg, -16'sd4096, 16'sd400);
    check_signed("Q_AVG (PF=-1.0)", q_avg, 16'sd0, 16'sd400);

    // -----------------------------------------------------------------------
    // Test Case 5: 50% Voltage Sag Transient (PF = 1.0)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 5: 50%% Voltage Sag Transient (PF = 1.0)", $time);
    current_phase_shift = 0.0;
    v_amplitude_scale   = 0.5;
    #(12.0 * GRID_PERIOD_NS);
    check_unsigned("V_RMS (50% Sag)", v_rms, 16'd5792, 16'd300);
    check_unsigned("I_RMS (Nominal)", i_rms, EXPECTED_RMS, 16'd300);
    check_signed("P_AVG (50% Sag)", p_avg, 16'sd2048, 16'sd400);

    // Restore nominal voltage
    v_amplitude_scale = 1.0;
    #(2.0 * GRID_PERIOD_NS);

    // -----------------------------------------------------------------------
    // Test Case 6: Zero Current Flow (Open Circuit, I = 0)
    // -----------------------------------------------------------------------
    $display("[%0t ns] Test 6: Zero Current Flow (Open Circuit)", $time);
    i_amplitude_scale = 0.0;
    #(24.0 * GRID_PERIOD_NS);
    check_unsigned("V_RMS (Nominal)", v_rms, EXPECTED_RMS, 16'd300);
    check_unsigned("I_RMS (Zero)", i_rms, 16'd0, 16'd100);
    check_signed("P_AVG (Zero)", p_avg, 16'sd0, 16'sd200);
    check_signed("Q_AVG (Zero)", q_avg, 16'sd0, 16'sd200);

    i_amplitude_scale = 1.0;

    $display("\n==================================================");
    if (error_count == 0) begin
      $display(" TEST PASSED: All Power Engine metrics within bounds!");
    end else begin
      $display(" TEST FAILED: %0d error(s) detected during assertion checks.", error_count);
    end
    $display("==================================================\n");
    $finish;
  end

  task automatic check_signed(input string name, input logic signed [15:0] actual,
                              input logic signed [15:0] expected,
                              input logic signed [15:0] tolerance);
    logic signed [15:0] diff;
    begin
      diff = actual - expected;
      if (diff < 0) diff = -diff;

      if (diff > tolerance) begin
        $display("[FAIL] %s | Expected: %0d, Got: %0d (Diff: %0d > Tol: %0d)", name, expected,
                 actual, diff, tolerance);
        error_count++;
      end else begin
        $display("[PASS] %s | Expected: %0d, Got: %0d", name, expected, actual);
      end
    end
  endtask

  task automatic check_unsigned(input string name, input logic [15:0] actual,
                                input logic [15:0] expected, input logic [15:0] tolerance);
    int diff;
    begin
      diff = $signed({1'b0, actual}) - $signed({1'b0, expected});
      if (diff < 0) diff = -diff;

      if (diff > tolerance) begin
        $display("[FAIL] %s | Expected: %0d, Got: %0d (Diff: %0d > Tol: %0d)", name, expected,
                 actual, diff, tolerance);
        error_count++;
      end else begin
        $display("[PASS] %s | Expected: %0d, Got: %0d", name, expected, actual);
      end
    end
  endtask

  // initial begin
  //   $dumpfile("sim/gen/vcd/current.vcd");
  //   $dumpvars(0, tb_power_engine);
  // end

endmodule
