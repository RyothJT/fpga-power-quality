`timescale 1ns / 1ps

/**
 * Module: thd_analyzer
 * Description: Estimates THD by isolating harmonics in the time domain.
 *              Filter strength (K) is dynamically calculated based on CLOCK_FREQ_HZ.
 *              Division is eliminated by normalizing harmonic power against nominal grid amplitude.
 *              Outputs all high (16'hffff) when pll is unlocked.
 */
module thd_analyzer #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real SAMPLE_RATE_HZ = CLOCK_FREQ_HZ / 100.0,
    parameter real CUTOFF_FREQ_HZ = 10.0,  // Aim for ~2Hz to heavily suppress 120Hz ripple
    parameter real GRID_PEAK_NOMINAL_Q15 = 32767.0  // Nominal peak amplitude in Q1.15
) (
    input logic clk,
    input logic rst_n,

    input logic measure_en,

    input logic signed [15:0] v_in,       // Raw Voltage (Q1.15)
    input logic signed [15:0] v_alpha,    // Fundamental Sine (Q1.15)
    input logic signed [15:0] v_beta,     // Fundamental Cosine (Q1.15)
    input logic               pll_locked,

    output logic [3:-12] thd_val,  // THD in Q4.12 format
    output logic [3:-12] thd_12c,  // THD averaged over 12 cycles per IEC 61000-4-30 standard

    output logic update_strobe  // Pulse high for 1 cycle when thd_12c is updated
);

  // -------------------------------------------------------------------------
  // 1. Dynamic Filter & Multiplicative Inverse Parameters
  // -------------------------------------------------------------------------
  // Formula: 2^K = F_clk / (2 * pi * F_cutoff)
  localparam real DIVISOR = SAMPLE_RATE_HZ / (2.0 * 3.14159265 * CUTOFF_FREQ_HZ);
  localparam int K = $clog2($rtoi(DIVISOR));

  // Pre-calculated Mean Square nominal reference: MS_nominal = (V_peak^2) / 2
  localparam real MS_NOMINAL = (GRID_PEAK_NOMINAL_Q15 * GRID_PEAK_NOMINAL_Q15) / 2;

  // Q0.32 fixed-point representation of inverse nominal mean square: (2^24) / MS_NOMINAL
  localparam real INV_MS_NOM_R = (2.0 ** 24) / MS_NOMINAL;
  localparam logic [31:0] INV_MS_NOM_Q32 = 32'($rtoi(INV_MS_NOM_R * (2.0 ** 16)));

  // -------------------------------------------------------------------------
  // 2. Time-Domain Harmonic Isolation (Pipelined Stage 1 & 2)
  // -------------------------------------------------------------------------
  logic signed [15:0] v_in_reg, va_reg, vb_reg;
  logic signed [15:0] v_harm_logic;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_in_reg     <= '0;
      va_reg       <= '0;
      vb_reg       <= '0;
      v_harm_logic <= '0;
    end else begin
      // Stage 1: Capture Raw Inputs
      v_in_reg     <= v_in;
      va_reg       <= v_alpha;
      vb_reg       <= v_beta;

      // Stage 2: Calculate Residual (Logic outside DSP)
      v_harm_logic <= v_in_reg - va_reg;
    end
  end

  // -------------------------------------------------------------------------
  // 3. Power Accumulation Pipeline (Pipelined Stage 3, 4, 5)
  // -------------------------------------------------------------------------

  // Stage 3: Clean Multiplier Inputs (AREG/BREG)
  logic signed [15:0] m_harm_a, m_fund_a, m_fund_b;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_harm_a <= '0;
      m_fund_a <= '0;
      m_fund_b <= '0;
    end else begin
      m_harm_a <= v_harm_logic;
      m_fund_a <= va_reg;
      m_fund_b <= vb_reg;
    end
  end

  // Stage 4: Multiplier Output (MREG)
  logic [31:0] p_harm_m, p_fund_a_m, p_fund_b_m;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_harm_m   <= '0;
      p_fund_a_m <= '0;
      p_fund_b_m <= '0;
    end else begin
      p_harm_m   <= m_harm_a * m_harm_a;
      p_fund_a_m <= m_fund_a * m_fund_a;
      p_fund_b_m <= m_fund_b * m_fund_b;
    end
  end

  // Stage 5: Final Multiplier Output (PREG)
  logic [31:0] p_harm_p, p_fund_a_p, p_fund_b_p;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_harm_p   <= '0;
      p_fund_a_p <= '0;
      p_fund_b_p <= '0;
    end else begin
      p_harm_p   <= p_harm_m;
      p_fund_a_p <= p_fund_a_m;
      p_fund_b_p <= p_fund_b_m;
    end
  end

  // Mean Square Inputs (Logic)
  logic [31:0] p_harm_inst_pipe;
  logic [31:0] p_fund_inst_pipe;
  assign p_harm_inst_pipe = p_harm_p;
  assign p_fund_inst_pipe = (p_fund_a_p + p_fund_b_p) >> 1;

  // IIR Accumulators
  logic [32+K-1:0] ms_harm_acc, ms_fund_acc;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ms_harm_acc <= '0;
      ms_fund_acc <= '0;
    end else if (measure_en) begin
      // The leaky integrator receives clean, registered power values
      ms_harm_acc <= ms_harm_acc + p_harm_inst_pipe - (ms_harm_acc >> K);
      ms_fund_acc <= ms_fund_acc + p_fund_inst_pipe - (ms_fund_acc >> K);
    end
  end

  // -------------------------------------------------------------------------
  // 4. Division-Free Ratio Calculation & Square Root (THD Calculation)
  // -------------------------------------------------------------------------

  logic [31:0] ms_harm, ms_fund;
  assign ms_harm = ms_harm_acc >> K;
  assign ms_fund = ms_fund_acc >> K;

  logic [ 31:0] thd_sq_q24;
  logic [3:-12] root_out;
  logic [ 63:0] thd_mult;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      thd_mult   <= '0;
      thd_sq_q24 <= '0;
    end else if (measure_en) begin
      if (pll_locked && ms_fund > 100) begin
        // Division replacement: multiply by Q0.32 inverse nominal constant
        thd_mult   <= 64'(ms_harm) * 64'(INV_MS_NOM_Q32);
        thd_sq_q24 <= thd_mult[47:16];
      end else begin
        thd_mult   <= '0;
        thd_sq_q24 <= '0;
      end
    end
  end

  // Square Root Instance
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

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_alpha_prev      <= 16'd0;
      cycle_cnt         <= 4'd0;
      window_sample_cnt <= 20'd0;
      thd_accumulator   <= 36'd0;
      thd_12c           <= '1;
      update_strobe     <= 1'b0;
    end else if (measure_en) begin
      v_alpha_prev <= v_alpha;

      if (!pll_locked) begin
        cycle_cnt         <= 4'd0;
        window_sample_cnt <= 20'd0;
        thd_accumulator   <= 36'd0;
        thd_12c           <= '1;
        update_strobe     <= 1'b0;
      end else begin
        // Accumulate instantaneous THD and count samples
        thd_accumulator   <= thd_accumulator + root_out;
        window_sample_cnt <= window_sample_cnt + 1'b1;

        update_strobe     <= 1'b0;
        if (cycle_start) begin
          if (cycle_cnt >= 11) begin
            // 12 Cycles reached: Calculate Mean and Reset
            if (window_sample_cnt > 0) begin
              thd_12c       <= 16'(thd_accumulator / window_sample_cnt);
              update_strobe <= 1'b1;
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
