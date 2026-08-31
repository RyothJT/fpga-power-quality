`timescale 1us / 1ns

module tb_dds_top;

  // -------------------------------------------------------------------------
  // Primary Parameters
  // -------------------------------------------------------------------------
  localparam real SIM_CLK_FREQ_HZ = 1_000_000.0;  // 100 MHz System Clock
  localparam real SAMPLE_FREQ_HZ = SIM_CLK_FREQ_HZ/100;  // 1 MHz Sample Rate (1 MSPS)
  localparam real CENTER_FREQ_HZ = 60.0;  // Fundamental grid frequency

  localparam real HALF_CLK_PERIOD_US = (1.0 / SIM_CLK_FREQ_HZ) * 1_000_000.0 / 2.0;
  localparam real LINE_PERIOD_US = (1.0 / CENTER_FREQ_HZ) * 1_000_000.0;

  reg        clk;
  reg        rst;
  reg [23:0] center_freq;  // Q16.8 format (60.0 Hz = 24'd15360)
  reg [4:0]  bit_precision;
  reg [14:0] v_peak;  // Q0.15
  reg [14:0] i_peak;  // Q0.15
  reg        jitter_en;
  reg [ 3:0] jitter_depth;
  reg [ 7:0] current_phase;

  // Harmonic Scale Controls (Q0.8)
  reg [7:0] v_h3_scale, v_h5_scale, v_h7_scale;
  reg [7:0] i_h3_scale, i_h5_scale, i_h7_scale;

  wire [15:0] v_out;
  wire [15:0] i_out;
  wire        sample_en;

  // Instantiate DDS Module
  dds_top #(
      .CLOCK_FREQ_HZ(SIM_CLK_FREQ_HZ),
      .TARGET_SAMPLE_RATE_HZ(SAMPLE_FREQ_HZ)
  ) uut (
      .clk(clk),
      .rst(rst),
      .sample_en(sample_en),
      .bit_precision(bit_precision),
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

  // Exact Clock Generator Derived from SIM_CLK_FREQ_HZ
  always #HALF_CLK_PERIOD_US clk = ~clk;

  function automatic [23:0] to_q16_8(input real freq_hz);
    begin
      to_q16_8 = 24'(integer'(freq_hz * 256.0));
    end
  endfunction

  initial begin
    // Initialize Signals
    clk           = 0;
    rst           = 1;
    center_freq   = to_q16_8(60.0);
    v_peak        = 15'h3FFF;
    i_peak        = 15'd1000;
    jitter_en     = 0;
    jitter_depth  = 4'd8;
    current_phase = 8'd32;
    bit_precision = 5'd16;

    v_h3_scale    = 8'd0;
    v_h5_scale    = 8'd0;
    v_h7_scale    = 8'd0;
    i_h3_scale    = 8'd0;
    i_h5_scale    = 8'd0;
    i_h7_scale    = 8'd0;

    #1;
    rst = 0;

    // --- Phase 1: Fundamental Waveforms @ 60 Hz ---
    $display("[%0t us] Phase 1: Clean fundamental V and I @ 60.0 Hz...", $time);
    #(LINE_PERIOD_US * 2);

    // --- Phase 2: Frequency Sweep ---
    $display("[%0t us] Phase 2: Shift center frequency to 50.0 Hz...", $time);
    center_freq = to_q16_8(50.0);
    #(LINE_PERIOD_US * 2);

    $display("[%0t us] Phase 2b: Shift center frequency to 400.0 Hz...", $time);
    center_freq = to_q16_8(400.0);
    #(LINE_PERIOD_US * 2);

    center_freq = to_q16_8(60.0);

    // --- Phase 3: Harmonics & Amplitude Modulation ---
    $display("[%0t us] Phase 3: Injecting harmonics...", $time);
    v_peak     = 15'h1FFF;
    v_h3_scale = 8'd8;
    v_h5_scale = 8'd5;
    i_h3_scale = 8'd77;
    i_h5_scale = 8'd38;
    i_h7_scale = 8'd20;
    #(LINE_PERIOD_US * 2);

    // --- Phase 4: Over-amplitude Guard ---
    $display("[%0t us] Phase 4: Testing over-amplitude v_peak...", $time);
    v_peak     = 15'h7FFF;
    v_h3_scale = 8'd128;
    v_h5_scale = 8'd64;
    #(LINE_PERIOD_US * 2);

    // --- Phase 5: Jitter Injection ---
    $display("[%0t us] Phase 5: Enabling Jitter...", $time);
    v_peak     = 15'h3FFF;
    v_h3_scale = 8'd0;
    v_h5_scale = 8'd0;
    jitter_en  = 1;
    #(LINE_PERIOD_US * 2);

    $display("[%0t us] Simulation Complete.", $time);
    $finish;
  end

  initial begin
    $dumpfile("sim/gen/vcd/current.vcd");
    $dumpvars(0, tb_dds_top);
  end

endmodule
