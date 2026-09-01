`timescale 1ns / 1ps

/**
 * Module: thd_analyzer
 * Description: Estimates THD by isolating harmonics in the time domain.
 *              Filter strength (K) is dynamically calculated based on CLOCK_FREQ_HZ.
 *              Outputs all high (16'ffff) when pll is unlocked.
 */
module thd_analyzer #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real SAMPLE_RATE_HZ = CLOCK_FREQ_HZ / 100,
    parameter real CUTOFF_FREQ_HZ = 10.0  // Aim for ~2Hz to heavily suppress 120Hz ripple
) (
    input logic clk,
    input logic rst_n,

    input logic measure_en,

    input logic signed [15:0] v_in,       // Raw Voltage (Q1.15)
    input logic signed [15:0] v_alpha,    // Fundamental Sine (Q1.15)
    input logic signed [15:0] v_beta,     // Fundamental Cosine (Q1.15)
    input logic               pll_locked,

    output logic [3:-12] thd_val,  // THD in Q4.12 format
    output logic [3:-12] thd_12c   // THD averaged over 12 cycles per IEC 61000-4-30 standard
);

  // -------------------------------------------------------------------------
  // 1. Dynamic Filter Parameter Calculation
  // -------------------------------------------------------------------------
  // Formula: 2^K = F_clk / (2 * pi * F_cutoff)
  localparam real DIVISOR = SAMPLE_RATE_HZ / (2.0 * 3.14159265 * CUTOFF_FREQ_HZ);
  localparam int K = $clog2($rtoi(DIVISOR));

  // -------------------------------------------------------------------------
  // 2. Time-Domain Harmonic Isolation
  // -------------------------------------------------------------------------
  // Subtract fundamental from raw signal before squaring.
  // This drastically reduces the ripple magnitude entering the filter.
  logic signed [15:0] v_harm_instant;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_harm_instant <= 16'd0;  // <--- MANDATORY: Initialize to 0
    end else if (measure_en) v_harm_instant <= v_in - v_alpha;
  end

  // -------------------------------------------------------------------------
  // 3. Power Accumulation (Mean Square)
  // -------------------------------------------------------------------------
  logic [31:0] p_harm_inst;
  logic [31:0] p_fund_inst;

  assign p_harm_inst = 32'($signed(v_harm_instant) * $signed(v_harm_instant));
  assign p_fund_inst = 32'((($signed(
      v_alpha
  ) * $signed(
      v_alpha
  )) + ($signed(
      v_beta
  ) * $signed(
      v_beta
  ))) >>> 1);

  // Accumulators scaled by dynamic K
  logic [32+K-1:0] ms_harm_acc;
  logic [32+K-1:0] ms_fund_acc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms_harm_acc <= '0;
      ms_fund_acc <= '0;
    end else if (measure_en) begin
      ms_harm_acc <= ms_harm_acc + p_harm_inst - (ms_harm_acc >> K);
      ms_fund_acc <= ms_fund_acc + p_fund_inst - (ms_fund_acc >> K);
    end
  end

  wire  [ 31:0] ms_harm = ms_harm_acc >> K;
  wire  [ 31:0] ms_fund = ms_fund_acc >> K;

  // -------------------------------------------------------------------------
  // 4. Ratio and Square Root (THD Calculation)
  // -------------------------------------------------------------------------
  logic [ 63:0] ratio_num;
  logic [ 31:0] thd_sq_q24;
  logic [-3:12] root_out;

  assign ratio_num = (64'(ms_harm) << 24);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      thd_sq_q24 <= '0;
    end else if (pll_locked && ms_fund > 100) begin
      thd_sq_q24 <= 32'(ratio_num / ms_fund);
    end else begin
      thd_sq_q24 <= '0;
    end
  end

  isqrt #(
      .WIDTH(32)
  ) u_isqrt_thd (
      .clk     (clk),
      .rst_n   (rst_n),
      .val_in  (thd_sq_q24),
      .root_out(root_out)
  );

  assign thd_val = pll_locked ? root_out : '1;

  // -------------------------------------------------------------------------
  // 5. IEC 61000-4-30 12-Cycle Averaging (200ms Window)
  // -------------------------------------------------------------------------
  logic signed [15:0] v_alpha_prev;
  logic               cycle_start;
  logic        [ 3:0] cycle_cnt;
  logic        [19:0] window_sample_cnt;
  logic        [35:0] thd_accumulator;

  // Detect positive-going zero crossing of fundamental sine (v_alpha)
  assign cycle_start = (v_alpha_prev < 0 && v_alpha >= 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_alpha_prev      <= 16'd0;
      cycle_cnt         <= 4'd0;
      window_sample_cnt <= 20'd0;
      thd_accumulator   <= 36'd0;
      thd_12c           <= '1;
    end else if (measure_en) begin
      v_alpha_prev <= v_alpha;

      if (!pll_locked) begin
        cycle_cnt         <= 4'd0;
        window_sample_cnt <= 20'd0;
        thd_accumulator   <= 36'd0;
        thd_12c           <= '1;
      end else begin
        // Accumulate instantaneous THD and count samples
        thd_accumulator   <= thd_accumulator + root_out;
        window_sample_cnt <= window_sample_cnt + 1'b1;

        if (cycle_start) begin
          if (cycle_cnt >= 11) begin
            // 12 Cycles reached: Calculate Mean and Reset
            // Division by window_sample_cnt (approx 200,000 at 1MSPS)
            if (window_sample_cnt > 0) begin
              thd_12c <= 16'(thd_accumulator / window_sample_cnt);
            end

            thd_accumulator   <= 36'd0;
            window_sample_cnt <= 20'd0;
            cycle_cnt         <= 4'd0;
          end else begin
            cycle_cnt <= cycle_cnt + 1'b1;
          end
        end
      end
    end
  end

endmodule
