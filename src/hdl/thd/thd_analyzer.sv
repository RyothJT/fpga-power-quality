`timescale 1ns / 1ps

/**
 * Module: thd_analyzer
 * Description: Estimates THD by isolating harmonics in the time domain.
 *              Filter strength (K) is dynamically calculated based on SAMPLE_RATE_HZ.
 *              Dynamic normalization against measured fundamental power (ms_fund)
 *              eliminates voltage-dependent magnitude scaling errors.
 *              Averages THD over 12 cycles using a multi-cycle divider
 *              to comply with IEC 61000-4-30 standard.
 *              Outputs all high (16'hffff) when PLL is unlocked.
 */
module thd_analyzer #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real SAMPLE_RATE_HZ = 1_000_000.0,  // 1 MSPS
    parameter real CUTOFF_FREQ_HZ = 10.0,  // ~2Hz to suppress 120Hz ripple
    parameter real GRID_PEAK_NOMINAL_Q15 = 16383.0,  // Nominal peak amplitude in Q1.15 (16'h3FFF)
    parameter real GRID_FREQ_HZ = 60.0  // Nominal grid frequency
) (
    input logic clk,
    input logic rst_n,

    input logic               measure_en,
    input logic signed [15:0] v_in,        // Raw Voltage (Q1.15)
    input logic signed [15:0] v_alpha,     // Fundamental Sine (Q1.15)
    input logic signed [15:0] v_beta,      // Fundamental Cosine (Q1.15)
    input logic               pll_locked,

    output logic [3:-12] thd_val,  // THD in Q4.12 format
    output logic [3:-12] thd_12c,  // THD averaged over 12 cycles per IEC 61000-4-30 standard

    output logic update_strobe  // Pulse high for 1 cycle when thd_12c is updated
);

  // -------------------------------------------------------------------------
  // 1. Dynamic Filter & Multiplicative Inverse Parameters
  // -------------------------------------------------------------------------
  // Formula: 2^K = F_sample / (2 * pi * F_cutoff)
  localparam real DIVISOR = SAMPLE_RATE_HZ / (2.0 * 3.14159265 * CUTOFF_FREQ_HZ);
  localparam int K = $clog2($rtoi(DIVISOR));

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
  // 4. Synthesizable Multi-Cycle Division (Dynamic ms_harm / ms_fund)
  // -------------------------------------------------------------------------
  logic [31:0] ms_harm, ms_fund;
  assign ms_harm = ms_harm_acc >> K;
  assign ms_fund = ms_fund_acc >> K;

  logic [ 31:0] thd_sq_q24;
  logic [3:-12] root_out;

  // Non-blocking Shift-and-Subtract Divider for Dynamic Power Normalization
  logic [ 63:0] div_num_norm;
  logic [ 31:0] div_den_norm;
  logic [ 31:0] div_quotient_norm;
  logic [  5:0] div_bit_cnt_norm;
  logic         div_busy_norm;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_num_norm      <= 64'd0;
      div_den_norm      <= 32'd0;
      div_quotient_norm <= 32'd0;
      div_bit_cnt_norm  <= 6'd0;
      div_busy_norm     <= 1'b0;
      thd_sq_q24        <= 32'd0;
    end else begin
      if (!div_busy_norm) begin
        // Idle state: wait for a trigger pulse (measure_en / sample_en)
        if (measure_en) begin
          if (ms_fund > 32'd100) begin
            // Start a new 32-bit Q24 division cycle
            div_num_norm      <= 64'(ms_harm) << 24;  // Align to Q24
            div_den_norm      <= ms_fund;
            div_quotient_norm <= 32'd0;
            div_bit_cnt_norm  <= 6'd32;
            div_busy_norm     <= 1'b1;
          end else begin
            // Denominator too small, clear result immediately
            thd_sq_q24 <= 32'd0;
          end
        end
      end else begin
        // Division in progress: runs independently on every clock edge
        if (div_bit_cnt_norm > 0) begin
          div_bit_cnt_norm <= div_bit_cnt_norm - 1'b1;
          if (div_num_norm >= (64'(div_den_norm) << (div_bit_cnt_norm - 1))) begin
            div_num_norm      <= div_num_norm - (64'(div_den_norm) << (div_bit_cnt_norm - 1));
            div_quotient_norm <= div_quotient_norm | (32'd1 << (div_bit_cnt_norm - 1));
          end
        end else begin
          // Division finished: store quotient and go back to idle
          div_busy_norm <= 1'b0;
          thd_sq_q24    <= div_quotient_norm;
        end
      end
    end
  end

  // Square Root Instance (Q24 Power -> Q12 Amplitude)
  isqrt #(
      .WIDTH(32)
  ) u_isqrt_thd (
      .clk     (clk),
      .rst_n   (rst_n),
      .val_in  (thd_sq_q24),
      .root_out(root_out)
  );

  assign thd_val = root_out;

  // -------------------------------------------------------------------------
  // 5. IEC 61000-4-30 12-Cycle Averaging (Multi-Cycle Division)
  // -------------------------------------------------------------------------
  logic signed [15:0] v_alpha_prev;
  logic               cycle_start;
  logic        [ 3:0] cycle_cnt;
  logic        [35:0] thd_accumulator;
  logic        [19:0] window_sample_cnt;

  // Non-blocking Divider State Machine Registers
  logic        [35:0] div_num;
  logic        [19:0] div_den;
  logic        [15:0] div_quotient;
  logic        [ 4:0] div_bit_cnt;
  logic               div_busy;

  // Detect positive-going zero crossing of fundamental sine (v_alpha)
  assign cycle_start = (v_alpha_prev < 0 && v_alpha >= 0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_alpha_prev      <= 16'd0;
      cycle_cnt         <= 4'd0;
      thd_accumulator   <= 36'd0;
      window_sample_cnt <= 20'd0;
      div_num           <= 36'd0;
      div_den           <= 20'd0;
      div_quotient      <= 16'd0;
      div_bit_cnt       <= 5'd0;
      div_busy          <= 1'b0;
      thd_12c           <= '1;
      update_strobe     <= 1'b0;
    end else begin
      update_strobe <= 1'b0;

      if (!pll_locked) begin
        cycle_cnt         <= 4'd0;
        thd_accumulator   <= 36'd0;
        window_sample_cnt <= 20'd0;
        div_busy          <= 1'b0;
        thd_12c           <= '1;
      end else begin
        // --- Continuous 12-Cycle Sample Accumulation ---
        if (measure_en) begin
          v_alpha_prev <= v_alpha;

          if (cycle_start) begin
            if (cycle_cnt >= 11) begin
              // 12 Cycles complete: Latch sum and total actual sample count
              div_num           <= thd_accumulator + root_out;
              div_den           <= window_sample_cnt + 1'b1;
              div_quotient      <= 16'd0;
              div_bit_cnt       <= 5'd16;  // Bit-shift count for Q4.12 precision
              div_busy          <= 1'b1;

              // Reset accumulator state for the next 12-cycle window
              thd_accumulator   <= 36'd0;
              window_sample_cnt <= 20'd0;
              cycle_cnt         <= 4'd0;
            end else begin
              thd_accumulator   <= thd_accumulator + root_out;
              window_sample_cnt <= window_sample_cnt + 1'b1;
              cycle_cnt         <= cycle_cnt + 1'b1;
            end
          end else begin
            // Normal in-window sample addition
            thd_accumulator   <= thd_accumulator + root_out;
            window_sample_cnt <= window_sample_cnt + 1'b1;
          end
        end

        // --- Multi-Cycle Shift-Subtract Divider Engine ---
        if (div_busy) begin
          if (div_bit_cnt > 0) begin
            div_bit_cnt <= div_bit_cnt - 1'b1;
            if (div_num >= ({16'd0, div_den} << (div_bit_cnt - 1))) begin
              div_num      <= div_num - ({16'd0, div_den} << (div_bit_cnt - 1));
              div_quotient <= div_quotient | (16'b1 << (div_bit_cnt - 1));
            end
          end else begin
            div_busy      <= 1'b0;
            thd_12c       <= div_quotient;  // Output in correct Q4.12 format
            update_strobe <= 1'b1;
          end
        end
      end
    end
  end

endmodule

