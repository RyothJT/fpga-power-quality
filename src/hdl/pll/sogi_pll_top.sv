`timescale 1ns / 1ps

module sogi_pll_top #(
    parameter real CLOCK_FREQ_HZ = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0,
    parameter logic [15:0] LOCK_THRESH = 16'd600,  // Lock threshold (lower bound)
    parameter logic [15:0] UNLOCK_THRESH = 16'd1200,  // Unlock threshold (upper bound)
    parameter logic [15:0] MIN_AMP_THRESH = 16'd2000,  // Minimum grid amplitude threshold
    parameter int CONSECUTIVE_LOCK_CYCLES = 3  // Cycles inside window to lock
) (
    input logic               clk,
    input logic               rst_n,
    input logic signed [15:0] v_in,

    input logic signed [15:0] k_sogi,
    input logic signed [15:0] kp_pll,
    input logic signed [15:0] ki_pll,

    output logic signed [ 15:0] v_alpha,
    output logic signed [ 15:0] v_beta,
    output logic signed [ 15:0] v_d,
    output logic signed [ 15:0] v_q,
    output logic        [ 15:0] theta,
    output logic        [15:-8] freq_out,

    output logic pll_locked
);

  // -------------------------------------------------------------------------
  // Local Parameters & Derived Math
  // -------------------------------------------------------------------------
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  localparam logic [31:0] NOMINAL_PERIOD_CLKS = 32'($rtoi(CLOCK_FREQ_HZ / CENTER_FREQ_HZ));
  localparam logic [63:0] FREQ_SCALE = CLOCK_FREQ_HZ * 256.0;

  // Allowed period variation window (+/- 15% of target frequency)
  localparam logic [31:0] MIN_PERIOD_CLKS = 32'($rtoi(NOMINAL_PERIOD_CLKS * 0.85));
  localparam logic [31:0] MAX_PERIOD_CLKS = 32'($rtoi(NOMINAL_PERIOD_CLKS * 1.15));

  logic [31:0] phase_inc;
  logic [31:0] phase_inc_smoothed;

  // -------------------------------------------------------------------------
  // 1. SOGI-QSG Sub-module Instance (Generates v_alpha & v_beta)
  // -------------------------------------------------------------------------
  sogi_qsg #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_sogi_qsg (
      .clk         (clk),
      .rst_n       (rst_n),
      .u_in        (v_in),
      .k_sogi      (k_sogi),
      .phase_inc_in(phase_inc_smoothed),
      .u_alpha     (v_alpha),
      .u_beta      (v_beta)
  );

  // -------------------------------------------------------------------------
  // 2. Closed-Loop NCO & Sine Lookup
  // -------------------------------------------------------------------------
  logic [31:0] phase_acc;
  logic signed [15:0] sin_val, cos_val;

  sine_rom #(
      .ADDR_WIDTH(12),
      .AMPLITUDE (16383.0)  // SOGI baseline (Q1.14)
  ) u_pll_rom (
      .clk(clk),
      .addr(phase_acc[31:20]),
      .sin_out(sin_val),
      .cos_out(cos_val)
  );

  logic signed [15:0] v_alpha_d1, v_beta_d1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_alpha_d1 <= '0;
      v_beta_d1  <= '0;
    end else begin
      v_alpha_d1 <= v_alpha;
      v_beta_d1  <= v_beta;
    end
  end

  // -------------------------------------------------------------------------
  // 3. Park Transform
  // -------------------------------------------------------------------------
  logic signed [31:0] mult_vd_a, mult_vd_b;
  logic signed [31:0] mult_vq_a, mult_vq_b;

  always_comb begin
    mult_vd_a = $signed(v_alpha_d1) * $signed(sin_val);
    mult_vd_b = $signed(v_beta_d1) * $signed(cos_val);

    mult_vq_a = $signed(v_alpha_d1) * $signed(cos_val);
    mult_vq_b = $signed(v_beta_d1) * $signed(sin_val);

    v_d = 16'((mult_vd_a - mult_vd_b) >>> 14);
    v_q = 16'((mult_vq_a + mult_vq_b) >>> 14);
  end

  // -------------------------------------------------------------------------
  // 4. PI Loop Filter & NCO Phase Accumulator
  // -------------------------------------------------------------------------
  logic signed [47:0] integrator_acc;
  logic signed [31:0] p_term;
  logic signed [31:0] i_term;
  logic signed [31:0] pi_out;
  localparam real CLK_GAIN_SCALE_R = 100_000_000.0 / CLOCK_FREQ_HZ;
  localparam logic signed [31:0] CLK_GAIN_SCALE = 32'($rtoi(CLK_GAIN_SCALE_R * 65536.0));  // Q16.16

  assign i_term = integrator_acc[47:16];

  always_comb begin
    p_term = $signed(v_q) * $signed(kp_pll);
    pi_out = p_term + i_term;
  end

  logic signed [47:0] ki_scaled;
  // Scale ki_pll proportionally so loop bandwidth remains fixed in Hz
  assign ki_scaled = ($signed(v_q) * $signed(ki_pll) * CLK_GAIN_SCALE) >>> 16;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      integrator_acc <= '0;
      phase_acc      <= '0;
    end else begin
      integrator_acc <= integrator_acc + 48'(ki_scaled);
      phase_acc      <= phase_acc + phase_inc;
    end
  end

  always_comb begin
    if ($signed(NOMINAL_PHASE_INC + pi_out) < $signed(32'd1)) begin
      phase_inc = 32'd1;
    end else begin
      phase_inc = NOMINAL_PHASE_INC + pi_out;
    end
  end

  // -------------------------------------------------------------------------
  // 5. Output & Phase-Reset Frequency Measurement & Smoothed Phase Inc
  // -------------------------------------------------------------------------
  assign theta = phase_acc[31:16];

  typedef enum logic {
    LOWER_ZONE,
    UPPER_ZONE
  } zone_e;
  zone_e current_zone;
  logic  phase_reset_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      current_zone      <= LOWER_ZONE;
      phase_reset_pulse <= 1'b0;
    end else begin
      phase_reset_pulse <= 1'b0;

      case (current_zone)
        LOWER_ZONE: begin
          if (phase_acc >= 32'hC000_0000) begin
            current_zone <= UPPER_ZONE;
          end
        end
        UPPER_ZONE: begin
          if (phase_acc < 32'h4000_0000) begin
            phase_reset_pulse <= 1'b1;
            current_zone      <= LOWER_ZONE;
          end
        end
      endcase
    end
  end

  logic [31:0] clk_counter;
  logic [31:0] measured_period_clks;

  // Accumulator for period-averaging phase_inc
  logic [63:0] phase_inc_sum;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clk_counter          <= '0;
      measured_period_clks <= NOMINAL_PERIOD_CLKS;
      phase_inc_sum        <= '0;
      phase_inc_smoothed   <= NOMINAL_PHASE_INC;
    end else begin
      clk_counter   <= clk_counter + 1'b1;
      phase_inc_sum <= phase_inc_sum + 64'(phase_inc);

      if (phase_reset_pulse) begin
        measured_period_clks <= clk_counter;
        clk_counter          <= '0;

        // Average phase_inc over the completed 60 Hz fundamental period
        if (clk_counter > 0) begin
          phase_inc_smoothed <= 32'(phase_inc_sum / 64'(clk_counter));
        end
        phase_inc_sum <= '0;
      end
    end
  end

  logic [63:0] freq_calc;
  assign freq_calc = FREQ_SCALE / 64'(measured_period_clks);
  assign freq_out  = freq_calc[23:0];

  // -------------------------------------------------------------------------
  // 6. Robust Lock-Detector with Fast Instant-Unlock & Synchronous Re-Lock
  // -------------------------------------------------------------------------
  logic signed [15:0] v_q_abs, v_alpha_abs, v_beta_abs;
  logic [47:0] v_q_abs_sum;
  logic [15:0] v_q_avg;
  logic [15:0] grid_amp_approx;
  logic [ 7:0] lock_counter;
  logic        amp_valid;
  logic        freq_valid;

  assign v_q_abs         = (v_q < 0) ? -v_q : -(-v_q);  // Safe absolute value calculation
  assign v_alpha_abs     = (v_alpha < 0) ? -v_alpha : v_alpha;
  assign v_beta_abs      = (v_beta < 0) ? -v_beta : v_beta;

  // Approximate vector magnitude (|alpha| + |beta|) for grid presence check
  assign grid_amp_approx = v_alpha_abs + v_beta_abs;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q_abs_sum  <= '0;
      v_q_avg      <= 16'hFFFF;
      lock_counter <= '0;
      pll_locked   <= 1'b0;
    end else begin
      v_q_abs_sum <= v_q_abs_sum + 48'(v_q_abs);

      // ---------------------------------------------------------------------
      // FAST UNLOCK PATH (Evaluated Every Clock Cycle)
      // ---------------------------------------------------------------------
      // Instantly drop lock if:
      //  1. Grid voltage collapses (grid_amp_approx < MIN_AMP_THRESH)
      //  2. Instantaneous Phase Error spikes high (v_q_abs > UNLOCK_THRESH)
      // ---------------------------------------------------------------------
      if ((grid_amp_approx < MIN_AMP_THRESH) || (v_q_abs > UNLOCK_THRESH)) begin
        pll_locked   <= 1'b0;
        lock_counter <= '0;
      end

      // ---------------------------------------------------------------------
      // SYNCHRONOUS RE-LOCK PATH (Evaluated on Fundamental Period Rollover)
      // ---------------------------------------------------------------------
      if (phase_reset_pulse) begin
        if (measured_period_clks > 0) begin
          v_q_avg <= 16'(v_q_abs_sum / 48'(measured_period_clks));
        end
        v_q_abs_sum <= '0;

        amp_valid = (grid_amp_approx >= MIN_AMP_THRESH);
        freq_valid = (measured_period_clks >= MIN_PERIOD_CLKS) && 
                     (measured_period_clks <= MAX_PERIOD_CLKS);

        // Standard Hysteresis & Counter Verification for Re-Locking
        if (amp_valid && freq_valid && (v_q_avg < LOCK_THRESH) && (v_q_abs <= UNLOCK_THRESH)) begin
          if (lock_counter < CONSECUTIVE_LOCK_CYCLES) begin
            lock_counter <= lock_counter + 1'b1;
          end else begin
            pll_locked <= 1'b1;
          end
        end else if (!amp_valid || !freq_valid || (v_q_avg > UNLOCK_THRESH)) begin
          lock_counter <= '0;
          pll_locked   <= 1'b0;
        end
      end
    end
  end

endmodule
