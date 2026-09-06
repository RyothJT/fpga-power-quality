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
    output logic        [ 31:0] phase_inc_smoothed,

    output logic pll_locked
);

  // -------------------------------------------------------------------------
  // Local Parameters & Derived Math
  // -------------------------------------------------------------------------
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * $pow(2, 32) / CLOCK_FREQ_HZ);
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  localparam logic [31:0] NOMINAL_PERIOD_CLKS = 32'($rtoi(CLOCK_FREQ_HZ / CENTER_FREQ_HZ));
  localparam logic [63:0] FREQ_SCALE = CLOCK_FREQ_HZ * $pow(2, 8);

  // Allowed period variation window (+/- 15% of target frequency)
  localparam logic [31:0] MIN_PERIOD_CLKS = 32'($rtoi(NOMINAL_PERIOD_CLKS * 0.85));
  localparam logic [31:0] MAX_PERIOD_CLKS = 32'($rtoi(NOMINAL_PERIOD_CLKS * 1.15));

  // Scaling constant to convert 32-bit phase_inc to Q16.8 frequency:
  localparam real FREQ_SCALE_FACTOR = (CLOCK_FREQ_HZ * $pow(2, 8)) / $pow(2, 32);
  localparam logic [31:0] FREQ_SCALE_Q16 = 32'($rtoi(FREQ_SCALE_FACTOR * $pow(2, 16)));


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

  // -------------------------------------------------------------------------
  // 3. Park Transform (Pipelined Stages 1, 2, & 3)
  // -------------------------------------------------------------------------

  // Stage 1: Input Isolation (AREG/BREG)
  // No resets on these to maximize DSP internal register absorption
  logic signed [15:0] va_pipe, vb_pipe;
  logic signed [15:0] sin_pipe, cos_pipe;

  always_ff @(posedge clk) begin
    va_pipe  <= v_alpha;
    vb_pipe  <= v_beta;
    sin_pipe <= sin_val;
    cos_pipe <= cos_val;
  end

  // Stage 2: DSP Products (MREG/PREG)
  logic signed [31:0] p_mult_vd_a, p_mult_vd_b;
  logic signed [31:0] p_mult_vq_a, p_mult_vq_b;

  always_ff @(posedge clk) begin
    p_mult_vd_a <= va_pipe * sin_pipe;
    p_mult_vd_b <= vb_pipe * cos_pipe;
    p_mult_vq_a <= va_pipe * cos_pipe;
    p_mult_vq_b <= vb_pipe * sin_pipe;
  end

  // Stage 3: Vector Summation & Saturation
  // We use logic signed [32:0] for the sum to prevent overflow
  logic signed [32:0] p_vd_sum, p_vq_sum;

  always_ff @(posedge clk) begin
    // 1. Declarations MUST come first in the block for Icarus
    logic signed [31:0] vd_s;
    logic signed [31:0] vq_s;

    if (!rst_n) begin
      p_vd_sum <= '0;
      p_vq_sum <= '0;
      v_d      <= '0;
      v_q      <= '0;
    end else begin
      // 2. Procedural assignments follow
      p_vd_sum <= $signed(p_mult_vd_a) - $signed(p_mult_vd_b);
      p_vq_sum <= $signed(p_mult_vq_a) + $signed(p_mult_vq_b);

      // Perform arithmetic shift
      vd_s = p_vd_sum >>> 14;
      vq_s = p_vq_sum >>> 14;

      // Apply Clamping
      v_d <= (vd_s > 32'sd32767) ? 16'sd32767 : (vd_s < -32'sd32768) ? -16'sd32768 : 16'(vd_s);

      v_q <= (vq_s > 32'sd32767) ? 16'sd32767 : (vq_s < -32'sd32768) ? -16'sd32768 : 16'(vq_s);
    end
  end

  // -------------------------------------------------------------------------
  // 4. PI Loop Filter (Pipelined for MREG/PREG)
  // -------------------------------------------------------------------------

  // MULTIPLIER PIPELINE: NO RESET
  (* use_dsp = "yes" *)logic signed [31:0] ki_stage1_mreg;
  (* use_dsp = "yes" *)logic signed [31:0] ki_stage1_preg;
  (* use_dsp = "yes" *)logic signed [31:0] p_term_mreg;
  (* use_dsp = "yes" *)logic signed [31:0] p_term_preg;

  always_ff @(posedge clk) begin
    p_term_mreg    <= $signed(v_q) * $signed(kp_pll);
    p_term_preg    <= p_term_mreg;

    ki_stage1_mreg <= $signed(v_q) * $signed(ki_pll);
    ki_stage1_preg <= ki_stage1_mreg;
  end

  // INTEGRATOR & NCO: RESET REQUIRED
  logic signed [47:0] integrator_acc;
  logic signed [31:0] pi_out_reg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      integrator_acc <= '0;
      pi_out_reg     <= '0;
      phase_acc      <= '0;
    end else begin
      // Stage 2 Multiplier (Gain Scaling) and Accumulation
      // Note: This 32x32 multiply is small enough to happen here if PREG is used above
      integrator_acc <= integrator_acc + 48'(($signed(
          ki_stage1_preg
      ) * $signed(
          {1'b0, NOMINAL_PHASE_INC}
      )) >>> 12);

      pi_out_reg <= p_term_preg + $signed(integrator_acc[47:16]);

      // NCO Phase Accumulator
      if ($signed(NOMINAL_PHASE_INC + pi_out_reg) < $signed(32'd1)) phase_acc <= phase_acc + 32'd1;
      else phase_acc <= phase_acc + 32'(NOMINAL_PHASE_INC + pi_out_reg);
    end
  end

  // -------------------------------------------------------------------------
  // 5. Output & Phase-Reset Frequency Measurement
  // -------------------------------------------------------------------------

  logic [31:0] phase_inc;

  // NCO Angle Output
  assign theta = phase_acc[31:16];

  // Instantaneous phase increment derived from the PI pipeline register.
  // This ensures the signal is never 'X' during the reset transition.
  assign phase_inc = ($signed(
      NOMINAL_PHASE_INC + pi_out_reg
  ) < $signed(
      32'd1
  )) ? 32'd1 : 32'(NOMINAL_PHASE_INC + pi_out_reg);

  // Rollover Detection State Machine (Zone-based)
  typedef enum logic {
    LOWER_ZONE,
    UPPER_ZONE
  } zone_e;
  zone_e current_zone;
  logic  phase_reset_pulse;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      current_zone      <= LOWER_ZONE;
      phase_reset_pulse <= 1'b0;
    end else begin
      phase_reset_pulse <= 1'b0;
      case (current_zone)
        LOWER_ZONE: begin
          if (phase_acc >= 32'hC000_0000) current_zone <= UPPER_ZONE;
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

  localparam int NOM_CYCLES_PER_PERIOD = CLOCK_FREQ_HZ / CENTER_FREQ_HZ;
  localparam int PHASE_EMA_SHIFT = $clog2(NOM_CYCLES_PER_PERIOD);  // e.g. 21 for 100MHz/60Hz

  // -------------------------------------------------------------------------
  // Continuous Phase Increment Smoother (Division-Free EMA Filter)
  // -------------------------------------------------------------------------
  // Extended precision accumulator depth dynamically matches PHASE_EMA_SHIFT + 32-bit input
  logic signed [32 + PHASE_EMA_SHIFT - 1 : 0] phase_inc_filter_acc;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phase_inc_filter_acc <= {NOMINAL_PHASE_INC, {(PHASE_EMA_SHIFT) {1'b0}}};
      phase_inc_smoothed   <= NOMINAL_PHASE_INC;
    end else begin
      // Update continuous accumulator on every clock cycle
      phase_inc_filter_acc <= phase_inc_filter_acc + $signed(
          {{(PHASE_EMA_SHIFT) {1'b0}}, phase_inc}
      ) - $signed(
          phase_inc_filter_acc >>> PHASE_EMA_SHIFT
      );

      // Extract high 32 bits as smoothed phase increment
      phase_inc_smoothed <= 32'(phase_inc_filter_acc >>> PHASE_EMA_SHIFT);
    end
  end

  logic [63:0] freq_calc_mult;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      freq_out <= 24'd0;
    end else begin
      freq_calc_mult <= 64'(phase_inc_smoothed) * 64'(FREQ_SCALE_Q16);
      freq_out       <= freq_calc_mult[39:16];
    end
  end

  // -------------------------------------------------------------------------
  // 6. Robust Lock-Detector with Fast Instant-Unlock & Synchronous Re-Lock
  // -------------------------------------------------------------------------
  // Compute EMA parameterization to match 1-period time constant (1 / CENTER_FREQ_HZ)
  localparam int PERIOD_CYCLES_R = CLOCK_FREQ_HZ / CENTER_FREQ_HZ;
  localparam int VQ_EMA_SHIFT = $clog2(PERIOD_CYCLES_R);  // e.g. 21 for 100MHz/60Hz

  logic        [31:0] clk_counter;
  logic        [31:0] measured_period_clks;

  logic signed [15:0] v_q_abs;
  logic signed [15:0] v_alpha_abs;
  logic signed [15:0] v_beta_abs;
  logic        [15:0] v_q_avg;
  logic        [15:0] grid_amp_approx;
  logic        [ 7:0] lock_counter;
  logic               amp_valid;
  logic               freq_valid;

  assign v_q_abs         = (v_q < 0) ? -v_q : v_q;
  assign v_alpha_abs     = (v_alpha < 0) ? -v_alpha : v_alpha;
  assign v_beta_abs      = (v_beta < 0) ? -v_beta : v_beta;

  // Approximate vector magnitude (|alpha| + |beta|) for grid presence check
  assign grid_amp_approx = v_alpha_abs + v_beta_abs;

  // Continuous low-pass filter accumulator for v_q_abs
  // Bit depth needs room for 16-bit input + VQ_EMA_SHIFT
  logic [16 + VQ_EMA_SHIFT - 1 : 0] v_q_filter_acc;

  // Continuous EMA filter replacing the period accumulator & division
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_q_filter_acc <= '1;  // Initialize high so lock isn't falsely asserted on startup
      v_q_avg        <= 16'hFFFF;
    end else begin
      v_q_filter_acc <= v_q_filter_acc 
                      + { {(VQ_EMA_SHIFT){1'b0}}, v_q_abs } 
                      - (v_q_filter_acc >> VQ_EMA_SHIFT);

      v_q_avg <= 16'(v_q_filter_acc >> VQ_EMA_SHIFT);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lock_counter         <= '0;
      pll_locked           <= 1'b0;
      clk_counter          <= '0;
      measured_period_clks <= NOMINAL_PERIOD_CLKS;
    end else begin
      clk_counter <= clk_counter + 1'b1;

      if (phase_reset_pulse) begin
        measured_period_clks <= clk_counter;
        clk_counter          <= '0;
      end

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
