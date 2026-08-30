`timescale 1us / 1ns

module tb_sogi_pll_top;

  // -------------------------------------------------------------------------
  // Primary Parameters
  // -------------------------------------------------------------------------
  localparam real SIM_CLK_FREQ_HZ = 100_000_000.0;  // Simulation clock frequency
  localparam real CENTER_FREQ_HZ = 6000.0;  // Fundamental nominal grid frequency

  // -------------------------------------------------------------------------
  // Relative Frequency Variations (Derived off CENTER_FREQ_HZ)
  // -------------------------------------------------------------------------
  localparam real FREQ_HIGH_1_HZ = CENTER_FREQ_HZ * 1.0333;  // +3.33% (e.g. 62 Hz @ 60 Hz baseline)
  localparam real FREQ_LOW_HZ = CENTER_FREQ_HZ * 0.9667;  // -3.33% (e.g. 58 Hz @ 60 Hz baseline)
  localparam real FREQ_HIGH_2_HZ = CENTER_FREQ_HZ * 1.0833;  // +8.33% (e.g. 65 Hz @ 60 Hz baseline)

  // -------------------------------------------------------------------------
  // Derived Clock & Dynamic Delay Calculations
  // -------------------------------------------------------------------------
  // Clock parameters (timescale is 1us)
  localparam real SIM_CLK_PERIOD_US = (1.0 / SIM_CLK_FREQ_HZ) * 1_000_000.0;
  localparam real HALF_PERIOD_US = SIM_CLK_PERIOD_US / 2.0;

  // Real-time durations scaled directly to fundamental line cycles
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
  logic [15:0] theta;
  logic [15:-8] freq_out;
  logic        pll_locked;

  // Testbench Variables
  real         tb_phase = 0.0;
  real         grid_freq = CENTER_FREQ_HZ;
  real         grid_amplitude = 16383.0;

  // Instantiate Design Under Test fully parameterized off SIM_CLK_FREQ_HZ and CENTER_FREQ_HZ
  sogi_pll_top #(
      .CLOCK_FREQ_HZ (SIM_CLK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) uut (
      .*
  );

  // Clock Generator derived from SIM_CLK_FREQ_HZ
  always #HALF_PERIOD_US clk = ~clk;

  initial begin
    clk    = 0;
    rst_n  = 0;
    v_in   = 0;

    // SOGI Damping Factor k = 1.414 (in Q1.14)
    k_sogi = 16'sd16384;
    kp_pll = 16'sd120;
    ki_pll = 16'sd40;

    #(SIM_CLK_PERIOD_US * 10);
    rst_n = 1;

    // 1. Initial Lock Phase
    #(LOCK_SETTLE_TIME);

    // 2. Inject a 90-degree Phase Step
    $display("\n[TB] --- Injecting 90-degree Phase Step into v_in ---");
    tb_phase = tb_phase + 1.57079632679;
    #(TRANSIENT_TIME);

    // 3. Inject a Frequency Jump (+3.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_HIGH_1_HZ);
    grid_freq = FREQ_HIGH_1_HZ;
    #(LOCK_SETTLE_TIME);

    // 4. Inject a Voltage Sag (80%)
    $display("\n[TB] --- Injecting Voltage Sag of 80%% ---");
    grid_amplitude = grid_amplitude * 0.8;
    #(TRANSIENT_TIME);
    grid_amplitude = 16383.0;

    // 5. Inject a Frequency Jump (-3.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_LOW_HZ);
    grid_freq = FREQ_LOW_HZ;
    #(LOCK_SETTLE_TIME);

    // 6. Inject a Frequency Jump (+8.33% offset)
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             FREQ_HIGH_2_HZ);
    grid_freq = FREQ_HIGH_2_HZ;
    #(LOCK_SETTLE_TIME);

    // 7. Return to Nominal Frequency
    $display("\n[TB] --- Injecting Frequency Jump: %0.1f Hz -> %0.1f Hz ---", grid_freq,
             CENTER_FREQ_HZ);
    grid_freq = CENTER_FREQ_HZ;
    #(FINAL_SETTLE_TIME);

    $finish;
  end

  // Phase increment per clock tick parameterized by SIM_CLK_FREQ_HZ
  always @(posedge clk) begin
    if (rst_n) begin
      tb_phase = tb_phase + (2.0 * 3.141592653589793 * grid_freq / SIM_CLK_FREQ_HZ);
      v_in     = $rtoi(grid_amplitude * $sin(tb_phase));
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
        $display("[TB] Rollover | Period = %0d us | freq_out: %0.2f Hz",
                 $time - last_time, $itor(freq_out) / 256.0);
        last_time <= $time;
      end
    end
  end

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_sogi_pll_top);
  end

endmodule
