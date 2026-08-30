`timescale 1ns / 1ps

/**
 * Module: sogi_pll_top
 * Description: Adaptive SOGI-PLL featuring 12-bit (4096-entry) Sine ROM and
 *              Period-Reset Frequency Measurement (Q8.8 format).
 */
module sogi_pll_top #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,  // System clock frequency
    parameter real CENTER_FREQ_HZ = 60.0            // Target nominal grid frequency
) (
    input logic               clk,
    input logic               rst_n,
    input logic signed [15:0] v_in,   // Nominal peak +/-16384

    input logic signed [15:0] k_sogi,  // 16'sd16384 = 1.0 (Q1.14)
    input logic signed [15:0] kp_pll,  // Proportional gain
    input logic signed [15:0] ki_pll,  // Integral gain

    output logic signed [ 15:0] v_alpha,
    output logic signed [ 15:0] v_beta,
    output logic signed [ 15:0] v_d,      // In-phase magnitude (~16384 at lock)
    output logic signed [ 15:0] v_q,      // Phase error (~0 at lock)
    output logic        [ 15:0] theta,    // Locked phase output [15:0] -> [31:16]
    output logic        [15:-8] freq_out, // Measured frequency output in Hz (Q8.8)

    output logic pll_locked
);

  // -------------------------------------------------------------------------
  // Parameter Derived Math & Constants
  // -------------------------------------------------------------------------
  localparam real M_PI = 3.14159265358979323846;

  // Nominal Phase Increment: (CENTER_FREQ * 2^32) / CLOCK_FREQ
  localparam real NOM_PHASE_INC_R = (CENTER_FREQ_HZ * 4294967296.0) / CLOCK_FREQ_HZ;
  localparam logic [31:0] NOMINAL_PHASE_INC = 32'($rtoi(NOM_PHASE_INC_R));

  // Nominal SOGI Integration Step: 2 * M_PI * NOMINAL_PHASE_INC
  localparam real NOM_W0_DT_R = 2.0 * M_PI * NOM_PHASE_INC_R;
  localparam logic signed [31:0] NOMINAL_W0_DT = 32'($rtoi(NOM_W0_DT_R));

  // Scaled 2*PI factor: (2 * PI) * 2^16 = 411740.8
  localparam real W0_SCALE_R = (2.0 * M_PI) * 65536.0;
  localparam logic signed [63:0] W0_SCALE_FACTOR = 64'($rtoi(W0_SCALE_R));

  // Dynamic Clamping bounds (-15% to +15% frequency variation)
  localparam logic signed [31:0] W0_DT_MIN = 32'($rtoi(NOM_W0_DT_R * (5.1 / 6.0)));
  localparam logic signed [31:0] W0_DT_MAX = 32'($rtoi(NOM_W0_DT_R * (6.9 / 6.0)));

  // Nominal Clock Cycles per Fundamental Period: CLOCK_FREQ / CENTER_FREQ
  localparam logic [31:0] NOMINAL_PERIOD_CLKS = 32'($rtoi(CLOCK_FREQ_HZ / CENTER_FREQ_HZ));

  // Assigning a real multiplication to a 64-bit logic parameter converts without 32-bit $rtoi truncation
  localparam logic [63:0] FREQ_SCALE = CLOCK_FREQ_HZ * 256.0;

  // -------------------------------------------------------------------------
  // Signal Declarations
  // -------------------------------------------------------------------------
  logic [31:0] phase_inc;

  // -------------------------------------------------------------------------
  // 1. Dynamic Frequency Adaptation (F-SOGI) - Ultra-Slow IIR Filter
  // -------------------------------------------------------------------------
  logic signed [31:0] w0_dt_dynamic;
  logic signed [47:0] w0_dt_iir_acc;
  logic signed [31:0] w0_dt_raw;
  logic signed [63:0] w0_mult_full;

  always_comb begin
    w0_mult_full = $signed({32'b0, phase_inc}) * W0_SCALE_FACTOR;
    w0_dt_raw    = 32'(w0_mult_full >>> 16);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w0_dt_iir_acc <= 48'(NOMINAL_W0_DT) <<< 16;
    end else begin
      // Tau ~ 65.5k clocks (ultra-slow smooth frequency adaptation)
      w0_dt_iir_acc <= w0_dt_iir_acc + 48'($signed(w0_dt_raw) - $signed(w0_dt_iir_acc[47:16]));
    end
  end

  // Hard clamp w0_dt to prevent runaway loop dynamics
  always_comb begin
    if (w0_dt_iir_acc[47:16] < W0_DT_MIN) w0_dt_dynamic = W0_DT_MIN;
    else if (w0_dt_iir_acc[47:16] > W0_DT_MAX) w0_dt_dynamic = W0_DT_MAX;
    else w0_dt_dynamic = w0_dt_iir_acc[47:16];
  end

  // -------------------------------------------------------------------------
  // 2. Adaptive SOGI Core
  // -------------------------------------------------------------------------
  logic signed [47:0] alpha_acc;
  logic signed [47:0] beta_acc;

  logic signed [15:0] alpha_state;
  logic signed [15:0] beta_state;
  logic signed [31:0] err;
  logic signed [31:0] k_err;
  logic signed [31:0] d_alpha_raw;
  logic signed [31:0] d_beta_raw;

  logic signed [63:0] d_alpha_ext, d_beta_ext;
  logic signed [63:0] w0_dt_ext;

  assign alpha_state = alpha_acc[47:32];
  assign beta_state  = beta_acc[47:32];

  always_comb begin
    err         = $signed(v_in) - $signed(alpha_state);
    k_err       = ($signed(err) * $signed(k_sogi)) >>> 14;
    d_alpha_raw = k_err - $signed(beta_state);
    d_beta_raw  = $signed(alpha_state);

    d_alpha_ext = 64'(d_alpha_raw);
    d_beta_ext  = 64'(d_beta_raw);
    w0_dt_ext   = 64'(w0_dt_dynamic);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      alpha_acc <= '0;
      beta_acc  <= '0;
    end else begin
      alpha_acc <= alpha_acc + 48'(d_alpha_ext * w0_dt_ext);
      beta_acc  <= beta_acc + 48'(d_beta_ext * w0_dt_ext);
    end
  end

  assign v_alpha = alpha_state;
  assign v_beta  = beta_state;

  // -------------------------------------------------------------------------
  // 3. Closed-Loop NCO & Sine Lookup (4096-entry lookup)
  // -------------------------------------------------------------------------
  logic [31:0] phase_acc;
  logic signed [15:0] sin_val, cos_val;

  sogi_sine_rom u_rom (
      .clk       (clk),
      .phase_addr(phase_acc[31:20]),  // Upper 12 bits select 4096 ROM entries
      .sin_val   (sin_val),
      .cos_val   (cos_val)
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
  // 4. Park Transform
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
  // 5. PI Loop Filter & NCO Phase Accumulator
  // -------------------------------------------------------------------------
  logic signed [47:0] integrator_acc;
  logic signed [31:0] p_term;
  logic signed [31:0] i_term;
  logic signed [31:0] pi_out;

  assign i_term = integrator_acc[47:16];

  always_comb begin
    p_term = $signed(v_q) * $signed(kp_pll);
    pi_out = p_term + i_term;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      integrator_acc <= '0;
      phase_acc      <= '0;
    end else begin
      integrator_acc <= integrator_acc + 48'($signed(v_q) * $signed(ki_pll));
      phase_acc      <= phase_acc + phase_inc;
    end
  end

  // Clamp phase increment to prevent negative steps
  always_comb begin
    if ($signed(NOMINAL_PHASE_INC + pi_out) < $signed(32'd1)) begin
      phase_inc = 32'd1;
    end else begin
      phase_inc = NOMINAL_PHASE_INC + pi_out;
    end
  end

  // -------------------------------------------------------------------------
  // 6. Output & Phase-Reset Frequency Measurement (Q8.8 Format)
  // -------------------------------------------------------------------------
  assign theta = phase_acc[31:16];

  // Hysteresis State Machine to reliably capture 2*PI -> 0 Phase Resets
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
            phase_reset_pulse <= 1'b1;  // High for 1 clock cycle upon phase reset
            current_zone      <= LOWER_ZONE;
          end
        end
      endcase
    end
  end

  // Count clock cycles between consecutive phase resets
  logic [31:0] clk_counter;
  logic [31:0] measured_period_clks;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clk_counter          <= '0;
      measured_period_clks <= NOMINAL_PERIOD_CLKS;
    end else begin
      clk_counter <= clk_counter + 1'b1;

      if (phase_reset_pulse) begin
        measured_period_clks <= clk_counter;
        clk_counter <= '0;
      end
    end
  end

  // Convert measured clock period into Q8.8 Frequency output:
  // freq_out (Q8.8) = (CLOCK_FREQ * 256) / measured_period_clks
  // 60.0 Hz = 15360 (16'h3C00)
  logic [63:0] freq_calc;
  assign freq_calc  = FREQ_SCALE / 64'(measured_period_clks);
  assign freq_out   = freq_calc[23:0];

  assign pll_locked = (v_q > -16'sd400) && (v_q < 16'sd400);

endmodule
