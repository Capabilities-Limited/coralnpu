// Differential test of rvv_softfloat_pkg against the host FPU (softfloat_ref.cpp).
`include "rvv_softfloat.svh"

module softfloat_tb;
  import rvv_softfloat_pkg::*;

  import "DPI-C" function int ref_op(input int op, input int a, input int b, input int c, input int rm, output int flags);
  import "DPI-C" function int ref_to_int(input int a, input int rm, input int is_signed, input int bits, output int flags);
  import "DPI-C" function int ref_from_int(input int x, input int rm, input int is_signed, input int bits, output int flags);

  `include "rtl_tables.svh"
  int errors = 0;
  int checks = 0;
  int N;

  task automatic check(string what, int a, int b, int c, int rm, logic [31:0] got, logic [4:0] got_fl, logic [31:0] exp, int exp_fl);
    checks++;
    if (got !== exp || got_fl !== exp_fl[4:0]) begin
      errors++;
      if (errors <= 40)
        $display("MISMATCH %s rm=%0d a=%08x b=%08x c=%08x : got %08x fl=%05b exp %08x fl=%05b", what, rm, a, b, c, got, got_fl, exp, exp_fl[4:0]);
    end
  endtask

  // Operand with a deliberate special-value bias. NaNs are canonicalised by the reference only on
  // the output, so they can be fed in raw.
  function automatic logic [31:0] opnd();
    return rand_fp32();
  endfunction

  initial begin
    int ra, rb, rc, rfl, rm;
    logic [31:0] a, b, c;
    fp_res_t r;
    if (!$value$plusargs("N=%d", N)) N = 200000;

    for (int i = 0; i < N; i++) begin
      a = opnd(); b = opnd(); c = opnd();
      rm = $urandom_range(0, 3);
      // add, sub, mul, div, fma, sqrt
      r = f_add(a, b, rm_e'(rm));      ra = ref_op(0, a, b, c, rm, rfl); check("add",  a, b, c, rm, r.val, r.fl, ra, rfl);
      r = f_sub(a, b, rm_e'(rm));      ra = ref_op(1, a, b, c, rm, rfl); check("sub",  a, b, c, rm, r.val, r.fl, ra, rfl);
      r = f_mul(a, b, rm_e'(rm));      ra = ref_op(2, a, b, c, rm, rfl); check("mul",  a, b, c, rm, r.val, r.fl, ra, rfl);
      r = f_div(a, b, rm_e'(rm));      ra = ref_op(3, a, b, c, rm, rfl); check("div",  a, b, c, rm, r.val, r.fl, ra, rfl);
      r = f_fma(a, b, c, rm_e'(rm));   ra = ref_op(4, a, b, c, rm, rfl); // RISC-V raises NV for inf*0 even with a quiet NaN addend; the host FPU does not
      if (!(f_is_nan(c) && !f_is_snan(c) && (f_is_inf(a) && f_is_zero(b) || f_is_zero(a) && f_is_inf(b))))
        check("fma",  a, b, c, rm, r.val, r.fl, ra, rfl);
      r = f_sqrt(a, rm_e'(rm));        ra = ref_op(5, a, b, c, rm, rfl); check("sqrt", a, b, c, rm, r.val, r.fl, ra, rfl);
      // conversions
      for (int sgn = 0; sgn < 2; sgn++) begin
        for (int w = 0; w < 2; w++) begin
          int bits = (w == 0) ? 32 : 16;
          r = f_to_int(a, rm_e'(rm), sgn[0], bits);
          ra = ref_to_int(a, rm, sgn, bits, rfl);
          // only the low `bits` bits are architectural
          check($sformatf("f2i s=%0d w=%0d", sgn, bits), a, 0, 0, rm,
                (bits == 32) ? r.val : (r.val & 32'hffff), r.fl,
                (bits == 32) ? ra    : (ra & 32'hffff), rfl);
          r = f_from_int(a, rm_e'(rm), sgn[0], bits);
          ra = ref_from_int(a, rm, sgn, bits, rfl);
          check($sformatf("i2f s=%0d w=%0d", sgn, bits), a, 0, 0, rm, r.val, r.fl, ra, rfl);
        end
      end
    end

    // Directed: RMM ties away from zero (not covered by fenv)
    r = f_add(32'h3f80_0000, 32'h3300_0000, RM_RMM);   // 1 + 2^-25: below half ulp -> stays 1
    if (r.val !== 32'h3f80_0000) begin errors++; $display("RMM add below half"); end
    r = f_add(32'h4b80_0000, 32'h3f80_0000, RM_RMM);   // 2^24 + 1 = tie between 2^24 and 2^24+2 -> away: +2
    if (r.val !== 32'h4b80_0001) begin errors++; $display("RMM add tie got %08x", r.val); end
    r = f_add(32'h4b80_0000, 32'h3f80_0000, RM_RNE);   // tie to even -> 2^24
    if (r.val !== 32'h4b80_0000) begin errors++; $display("RNE add tie got %08x", r.val); end
    r = f_to_int(32'h4020_0000, RM_RMM, 1'b1, 32);     // 2.5 -> 3
    if (r.val !== 32'd3) begin errors++; $display("RMM cvt 2.5 got %0d", r.val); end
    r = f_to_int(32'hc020_0000, RM_RMM, 1'b1, 32);     // -2.5 -> -3
    if (r.val !== 32'hffff_fffd) begin errors++; $display("RMM cvt -2.5 got %08x", r.val); end

    // Directed: int16 -> float must sign-extend (signed) / zero-extend (unsigned) the low 16 bits
    r = f_from_int(32'hdead_ffff, RM_RNE, 1'b1, 16); if (r.val !== 32'hbf80_0000) begin errors++; $display("i2f s16 got %08x", r.val); end
    r = f_from_int(32'hdead_ffff, RM_RNE, 1'b0, 16); if (r.val !== 32'h477f_ff00) begin errors++; $display("i2f u16 got %08x", r.val); end

    // Directed: min/max, class, compare, sign
    r = f_minmax(32'h8000_0000, 32'h0000_0000, 1'b0); if (r.val !== 32'h8000_0000) begin errors++; $display("fmin -0 +0"); end
    r = f_minmax(32'h8000_0000, 32'h0000_0000, 1'b1); if (r.val !== 32'h0000_0000) begin errors++; $display("fmax -0 +0"); end
    r = f_minmax(32'h7fc0_0000, 32'h3f80_0000, 1'b0); if (r.val !== 32'h3f80_0000 || r.fl !== 0) begin errors++; $display("fmin nan"); end
    r = f_minmax(32'h7f80_0001, 32'h3f80_0000, 1'b0); if (r.val !== 32'h3f80_0000 || r.fl !== FL_NV) begin errors++; $display("fmin snan"); end
    if (f_class(32'hff80_0000) !== 10'h001 || f_class(32'h7f80_0000) !== 10'h080 || f_class(32'h0) !== 10'h010 ||
        f_class(32'h8000_0000) !== 10'h008 || f_class(32'h7fc0_0000) !== 10'h200 || f_class(32'h7f80_0001) !== 10'h100 ||
        f_class(32'h0000_0001) !== 10'h020 || f_class(32'h8000_0001) !== 10'h004 || f_class(32'h3f80_0000) !== 10'h040 ||
        f_class(32'hbf80_0000) !== 10'h002) begin errors++; $display("fclass"); end

    // rec7 / rsqrt7 spot checks against values from the RVV spec examples
    r = f_rec7(32'h3f80_0000, RM_RNE);  // 1.0 -> 0.99609375 (table[0] = 127): 0x3f7f0000
    if (r.val !== 32'h3f7f_0000) begin errors++; $display("rec7(1.0) got %08x", r.val); end
    r = f_rsqrt7(32'h3f80_0000);        // 1.0 -> ~0.996: 0x3f7f0000
    if (r.val !== 32'h3f7f_0000) begin errors++; $display("rsqrt7(1.0) got %08x", r.val); end

    // rec7 / rsqrt7 generated tables vs the RTL tables
    for (int i = 0; i < 128; i++) begin
      if (rec7_table(7'(i))   !== RTL_REC7[i])   begin errors++; if (errors < 40) $display("rec7 table[%0d]: got %0d RTL %0d", i, rec7_table(7'(i)), RTL_REC7[i]); end
      if (rsqrt7_table(7'(i)) !== RTL_RSQRT7[i]) begin errors++; if (errors < 40) $display("rsqrt7 table[%0d]: got %0d RTL %0d", i, rsqrt7_table(7'(i)), RTL_RSQRT7[i]); end
    end

    // Worked examples and tables from the RVV spec (vfrsqrt7 / vfrec7 sections)
    r = f_rsqrt7(32'h0071_8abc); if (r.val !== 32'h5f08_0000 || r.fl !== 0) begin errors++; $display("spec rsqrt7 #1 got %08x fl=%b", r.val, r.fl); end
    r = f_rsqrt7(32'h7f76_5432); if (r.val !== 32'h1f82_0000 || r.fl !== 0) begin errors++; $display("spec rsqrt7 #2 got %08x fl=%b", r.val, r.fl); end
    r = f_rec7(32'h0071_8abc, RM_RNE); if (r.val !== 32'h7e90_0000 || r.fl !== 0) begin errors++; $display("spec rec7 #1 got %08x fl=%b", r.val, r.fl); end
    r = f_rec7(32'h7f76_5432, RM_RNE); if (r.val !== 32'h0021_4000 || r.fl !== 0) begin errors++; $display("spec rec7 #2 got %08x fl=%b", r.val, r.fl); end
    // vfrec7 of a subnormal below 2^-(B+1): overflow, the result depends on the rounding mode
    for (int rmv = 0; rmv < 5; rmv++) begin
      logic [31:0] ep, en;
      // positive: RUP, RNE, RMM -> +inf ; RDN, RTZ -> greatest finite
      ep = (rmv == 1 || rmv == 2) ? 32'h7f7f_ffff : 32'h7f80_0000;
      // negative: RUP, RTZ -> greatest-magnitude finite ; RDN, RNE, RMM -> -inf
      en = (rmv == 1 || rmv == 3) ? 32'hff7f_ffff : 32'hff80_0000;
      r = f_rec7(32'h0000_0001, rm_e'(rmv)); if (r.val !== ep || r.fl !== (FL_OF|FL_NX)) begin errors++; $display("spec rec7 +tiny rm=%0d got %08x fl=%b", rmv, r.val, r.fl); end
      r = f_rec7(32'h8000_0001, rm_e'(rmv)); if (r.val !== en || r.fl !== (FL_OF|FL_NX)) begin errors++; $display("spec rec7 -tiny rm=%0d got %08x fl=%b", rmv, r.val, r.fl); end
    end
    // 2^-(B+1) = 2^-128 is the smallest subnormal that still gives a (normal) finite result
    r = f_rec7(32'h0020_0000, RM_RNE); if (r.fl !== 0 || f_is_inf(r.val)) begin errors++; $display("spec rec7 2^-128 got %08x fl=%b", r.val, r.fl); end
    r = f_rec7(32'h001f_ffff, RM_RNE); if (r.fl !== (FL_OF|FL_NX) || !f_is_inf(r.val)) begin errors++; $display("spec rec7 just below 2^-128 got %08x fl=%b", r.val, r.fl); end
    // rsqrt7: -inf <= x < -0.0 is invalid, +-0 divide by zero, NaNs canonicalise
    r = f_rsqrt7(32'hff80_0000); if (r.val !== QNAN || r.fl !== FL_NV) begin errors++; $display("rsqrt7(-inf)"); end
    r = f_rsqrt7(32'h8000_0001); if (r.val !== QNAN || r.fl !== FL_NV) begin errors++; $display("rsqrt7(-sub)"); end
    r = f_rsqrt7(32'h8000_0000); if (r.val !== 32'hff80_0000 || r.fl !== FL_DZ) begin errors++; $display("rsqrt7(-0)"); end
    r = f_rsqrt7(32'h7f80_0000); if (r.val !== 32'h0 || r.fl !== 0) begin errors++; $display("rsqrt7(+inf)"); end
    r = f_rec7(32'h7f80_0001, RM_RNE); if (r.val !== QNAN || r.fl !== FL_NV) begin errors++; $display("rec7(snan)"); end
    r = f_rec7(32'h7fc0_1234, RM_RNE); if (r.val !== QNAN || r.fl !== 0) begin errors++; $display("rec7(qnan)"); end

    $display("softfloat_tb: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("softfloat_tb: PASS"); else $display("softfloat_tb: FAIL");
    $finish;
  end
endmodule
