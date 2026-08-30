`timescale 1ns / 1ps

module sogi_pll_top #(
    parameter real CLOCK_FREQ_HZ  = 100_000_000.0,
    parameter real CENTER_FREQ_HZ = 60.0
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

  logic [31:0] phase_inc;

  // -------------------------------------------------------------------------
  // 1. SOGI-QSG Sub-module Instance (Generates v_alpha & v_beta)
  // -------------------------------------------------------------------------
  sogi_qsg #(
      .CLOCK_FREQ_HZ (CLOCK_FREQ_HZ),
      .CENTER_FREQ_HZ(CENTER_FREQ_HZ)
  ) u_sogi_qsg (
      .clk    (clk),
      .rst_n  (rst_n),
      .u_in   (v_in),
      .k_sogi (k_sogi),
      .u_alpha(v_alpha),
      .u_beta (v_beta)
  );

  // -------------------------------------------------------------------------
  // 2. Closed-Loop NCO & Sine Lookup
  // -------------------------------------------------------------------------
  logic [31:0] phase_acc;
  logic signed [15:0] sin_val, cos_val;

  sogi_sine_rom u_rom (
      .clk       (clk),
      .phase_addr(phase_acc[31:20]),
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

  always_comb begin
    if ($signed(NOMINAL_PHASE_INC + pi_out) < $signed(32'd1)) begin
      phase_inc = 32'd1;
    end else begin
      phase_inc = NOMINAL_PHASE_INC + pi_out;
    end
  end

  // -------------------------------------------------------------------------
  // 5. Output & Phase-Reset Frequency Measurement (Q8.8 Format)
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clk_counter          <= '0;
      measured_period_clks <= NOMINAL_PERIOD_CLKS;
    end else begin
      clk_counter <= clk_counter + 1'b1;

      if (phase_reset_pulse) begin
        measured_period_clks <= clk_counter;
        clk_counter          <= '0;
      end
    end
  end

  logic [63:0] freq_calc;
  assign freq_calc  = FREQ_SCALE / 64'(measured_period_clks);
  assign freq_out   = freq_calc[23:0];

  assign pll_locked = (v_q > -16'sd400) && (v_q < 16'sd400);

endmodule
