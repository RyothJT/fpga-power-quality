`timescale 1ns / 1ps

module dds_top #(
    parameter PHASE_ACC_WIDTH = 32,
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real SAMPLE_RATE_HZ = 20_000.0
) (
    input  wire         clk,
    input  wire         rst,
    output reg          sample_en,
    output reg          measure_en,
    input  wire  [ 4:0] bit_precision,
    input  wire  [23:0] center_freq,
    input  wire  [14:0] v_peak,
    input  wire  [14:0] i_peak,
    input  wire         jitter_en,
    input  wire  [ 3:0] jitter_depth,
    input  wire  [ 7:0] current_phase,
    input  wire  [ 7:0] v_h3_scale,
    v_h5_scale,
    v_h7_scale,
    input  wire  [ 7:0] i_h3_scale,
    i_h5_scale,
    i_h7_scale,
    output logic [15:0] v_out,
    output logic [15:0] i_out
);

  // -------------------------------------------------------------------------
  // 1. Clock Divider & Base Frequency (Strict DSP Pipeline)
  // -------------------------------------------------------------------------
  localparam integer DIV_LIMIT = (CLOCK_FREQ_HZ / SAMPLE_RATE_HZ < 1) ? 1 : $rtoi(
      CLOCK_FREQ_HZ / SAMPLE_RATE_HZ
  );
  localparam real ACTUAL_SAMPLE_RATE_HZ = CLOCK_FREQ_HZ / DIV_LIMIT;
  localparam logic [31:0] FREQ_MULT = 32'($rtoi((16777216.0 / ACTUAL_SAMPLE_RATE_HZ) * 65536.0));

  logic [31:0] clk_div_cnt, phase_acc, m_base;

  // MULTIPLIER PIPELINE: NO RESETS, NO LOGIC, NO CASTS
  // We add 1 bit of padding and use $signed to force DSP48 mapping
  (* use_dsp = "yes" *)logic signed [24:0] base_a_in;  // 24-bit freq + 1 zero bit
  (* use_dsp = "yes" *)logic signed [32:0] base_b_in;  // 32-bit mult + 1 zero bit
  (* use_dsp = "yes" *)logic signed [57:0] base_mreg;  // The "Lonely" Multiplier
  (* use_dsp = "yes" *)logic signed [57:0] base_preg;  // The Output Register

  always_ff @(posedge clk) begin
    // Stage 1: AREG/BREG (Clean input registers)
    base_a_in <= $signed({1'b0, center_freq});
    base_b_in <= $signed({1'b0, FREQ_MULT});

    // Stage 2: MREG (The Multiplier line must be completely naked)
    base_mreg <= base_a_in * base_b_in;

    // Stage 3: PREG (Clean output register)
    base_preg <= base_mreg;

    // Stage 4: Map back to the functional signal
    m_base <= base_preg[47:16];
  end

  // CONTROL LOGIC: RESET ALLOWED HERE
  always_ff @(posedge clk) begin
    if (rst) begin
      clk_div_cnt <= '0;
      phase_acc   <= '0;
      sample_en   <= 1'b0;
      measure_en  <= 1'b0;
    end else begin
      sample_en   <= (clk_div_cnt == DIV_LIMIT - 1);
      measure_en  <= (clk_div_cnt == (DIV_LIMIT >> 1));
      clk_div_cnt <= (clk_div_cnt >= DIV_LIMIT - 1) ? '0 : clk_div_cnt + 1'b1;

      if (sample_en) phase_acc <= phase_acc + m_base;
    end
  end

  // -------------------------------------------------------------------------
  // 2. Address Generation (Reset required)
  // -------------------------------------------------------------------------
  wire [15:0] rnd_word;
  lfsr_random u_lfsr (
      .clk(clk),
      .rst(rst),
      .rnd_out(rnd_word)
  );
  wire signed [11:0] jitter = jitter_en ? ($signed(rnd_word) >>> (16 - jitter_depth)) : 12'sd0;

  logic [11:0] v_addr_h1, v_addr_h3, v_addr_h5, v_addr_h7;
  logic [11:0] i_addr_h1, i_addr_h3, i_addr_h5, i_addr_h7;

  always_ff @(posedge clk) begin
    if (rst) begin
      {v_addr_h1, v_addr_h3, v_addr_h5, v_addr_h7} <= '0;
      {i_addr_h1, i_addr_h3, i_addr_h5, i_addr_h7} <= '0;
    end else begin
      v_addr_h1 <= phase_acc[31:20] + $unsigned(jitter);
      i_addr_h1 <= (phase_acc[31:20] + $unsigned(jitter)) - {current_phase, 4'b0};
      v_addr_h3 <= v_addr_h1 * 3;
      v_addr_h5 <= v_addr_h1 * 5;
      v_addr_h7 <= v_addr_h1 * 7;
      i_addr_h3 <= i_addr_h1 * 3;
      i_addr_h5 <= i_addr_h1 * 5;
      i_addr_h7 <= i_addr_h1 * 7;
    end
  end

  // -------------------------------------------------------------------------
  // 3. ROM Lookups
  // -------------------------------------------------------------------------
  wire signed [15:0] raw_v_h1, raw_v_h3, raw_v_h5, raw_v_h7;
  wire signed [15:0] raw_i_h1, raw_i_h3, raw_i_h5, raw_i_h7;

  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_v_h1 (
      .clk(clk),
      .addr(v_addr_h1),
      .sin_out(raw_v_h1)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_v_h3 (
      .clk(clk),
      .addr(v_addr_h3),
      .sin_out(raw_v_h3)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_v_h5 (
      .clk(clk),
      .addr(v_addr_h5),
      .sin_out(raw_v_h5)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_v_h7 (
      .clk(clk),
      .addr(v_addr_h7),
      .sin_out(raw_v_h7)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_i_h1 (
      .clk(clk),
      .addr(i_addr_h1),
      .sin_out(raw_i_h1)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_i_h3 (
      .clk(clk),
      .addr(i_addr_h3),
      .sin_out(raw_i_h3)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_i_h5 (
      .clk(clk),
      .addr(i_addr_h5),
      .sin_out(raw_i_h5)
  );
  sine_rom #(
      .AMPLITUDE(32767.0)
  ) u_rom_i_h7 (
      .clk(clk),
      .addr(i_addr_h7),
      .sin_out(raw_i_h7)
  );

  // -------------------------------------------------------------------------
  // 4. Harmonic Scaling (Pipelined with Resets)
  // -------------------------------------------------------------------------
  logic signed [15:0] vh3_a, vh5_a, vh7_a, ih3_a, ih5_a, ih7_a;
  logic signed [8:0] vh3_b, vh5_b, vh7_b, ih3_b, ih5_b, ih7_b;
  logic signed [24:0] vh3_m, vh5_m, vh7_m, ih3_m, ih5_m, ih7_m;
  logic signed [24:0] vh3_p, vh5_p, vh7_p, ih3_p, ih5_p, ih7_p;

  always_ff @(posedge clk) begin
    if (rst) begin
      {vh3_a, vh5_a, vh7_a, ih3_a, ih5_a, ih7_a} <= '0;
      {vh3_b, vh5_b, vh7_b, ih3_b, ih5_b, ih7_b} <= '0;
      {vh3_m, vh5_m, vh7_m, ih3_m, ih5_m, ih7_m} <= '0;
      {vh3_p, vh5_p, vh7_p, ih3_p, ih5_p, ih7_p} <= '0;
    end else begin
      vh3_a <= raw_v_h3;
      vh3_b <= $signed({1'b0, v_h3_scale});
      vh3_m <= vh3_a * vh3_b;
      vh3_p <= vh3_m;
      vh5_a <= raw_v_h5;
      vh5_b <= $signed({1'b0, v_h5_scale});
      vh5_m <= vh5_a * vh5_b;
      vh5_p <= vh5_m;
      vh7_a <= raw_v_h7;
      vh7_b <= $signed({1'b0, v_h7_scale});
      vh7_m <= vh7_a * vh7_b;
      vh7_p <= vh7_m;
      ih3_a <= raw_i_h3;
      ih3_b <= $signed({1'b0, i_h3_scale});
      ih3_m <= ih3_a * ih3_b;
      ih3_p <= ih3_m;
      ih5_a <= raw_i_h5;
      ih5_b <= $signed({1'b0, i_h5_scale});
      ih5_m <= ih5_a * ih5_b;
      ih5_p <= ih5_m;
      ih7_a <= raw_i_h7;
      ih7_b <= $signed({1'b0, i_h7_scale});
      ih7_m <= ih7_a * ih7_b;
      ih7_p <= ih7_m;
    end
  end

  // -------------------------------------------------------------------------
  // 5. Summation & Peak Scaling (Pipelined with Resets)
  // -------------------------------------------------------------------------
  logic signed [15:0] vh1_d1, vh1_d2, vh1_d3, ih1_d1, ih1_d2, ih1_d3;
  logic signed [17:0] v_comp, i_comp;
  logic signed [17:0] peak_v_a, peak_i_a;
  logic signed [15:0] peak_v_b, peak_i_b;
  logic signed [33:0] peak_v_m, peak_v_p, peak_i_m, peak_i_p;

  always_ff @(posedge clk) begin
    if (rst) begin
      {vh1_d1, vh1_d2, vh1_d3, ih1_d1, ih1_d2, ih1_d3} <= '0;
      {v_comp, i_comp, peak_v_a, peak_i_a} <= '0;
      {peak_v_b, peak_i_b} <= '0;
      {peak_v_m, peak_v_p, peak_i_m, peak_i_p} <= '0;
    end else begin
      vh1_d1 <= raw_v_h1;
      vh1_d2 <= vh1_d1;
      vh1_d3 <= vh1_d2;
      ih1_d1 <= raw_i_h1;
      ih1_d2 <= ih1_d1;
      ih1_d3 <= ih1_d2;

      v_comp <= $signed(
          vh1_d3
      ) + 18'($signed(
          vh3_p >>> 8
      )) + 18'($signed(
          vh5_p >>> 8
      )) + 18'($signed(
          vh7_p >>> 8
      ));
      i_comp <= $signed(
          ih1_d3
      ) + 18'($signed(
          ih3_p >>> 8
      )) + 18'($signed(
          ih5_p >>> 8
      )) + 18'($signed(
          ih7_p >>> 8
      ));

      peak_v_a <= v_comp;
      peak_v_b <= $signed({1'b0, v_peak});
      peak_v_m <= 34'($signed(peak_v_a) * $signed(peak_v_b));
      peak_v_p <= peak_v_m;

      peak_i_a <= i_comp;
      peak_i_b <= $signed({1'b0, i_peak});
      peak_i_m <= 34'($signed(peak_i_a) * $signed(peak_i_b));
      peak_i_p <= peak_i_m;
    end
  end

  // -------------------------------------------------------------------------
  // 6. Output (Sign-Safe)
  // -------------------------------------------------------------------------
  logic signed [33:0] v_final_s, i_final_s;
  logic [15:0] v_sat, i_sat;

  always_comb begin
    v_final_s = peak_v_p >>> 15;
    i_final_s = peak_i_p >>> 15;
    v_sat = (v_final_s > 34'sd32767)  ? 16'sd32767 : (v_final_s < -34'sd32768) ? -16'sd32768 : 16'(v_final_s);
    i_sat = (i_final_s > 34'sd32767)  ? 16'sd32767 : (i_final_s < -34'sd32768) ? -16'sd32768 : 16'(i_final_s);
  end

  wire [15:0] mask = 16'hFFFF << ((bit_precision < 16) ? (16 - bit_precision) : 0);

  always_ff @(posedge clk) begin
    if (rst) begin
      v_out <= '0;
      i_out <= '0;
    end else begin
      v_out <= v_sat & mask;
      i_out <= i_sat & mask;
    end
  end
endmodule
