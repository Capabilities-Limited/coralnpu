`ifndef RVV_SOFTFLOAT__SVH
`define RVV_SOFTFLOAT__SVH

// Bit-exact IEEE-754 binary32 reference arithmetic for the RVV floating point model.
//
// Every operation follows the RISC-V "F" rules that RVV 1.0 reuses (RISC-V unprivileged spec ch.
// "F" and RVV spec ch. 13):
//   - the five rounding modes RNE, RTZ, RDN, RUP and RMM,
//   - tininess is detected AFTER rounding,
//   - every NaN result is the canonical quiet NaN 0x7fc00000,
//   - fflags are returned as {NV, DZ, OF, UF, NX} (bit 4 .. bit 0),
//   - no flush-to-zero: subnormals are handled exactly.
// Arithmetic is exact in a wide integer and rounded once, so no host floating point is involved.
package rvv_softfloat_pkg;

  // Width of the exact integer used while adding. A fused multiply-add can need about 550 bits.
  localparam int W = 640;
  typedef logic [W-1:0] wide_t;

  // Rounding modes, the encoding of the frm CSR / rm field.
  typedef enum logic [2:0] {
    RM_RNE = 3'b000,
    RM_RTZ = 3'b001,
    RM_RDN = 3'b010,
    RM_RUP = 3'b011,
    RM_RMM = 3'b100
  } rm_e;

  localparam logic [4:0] FL_NV = 5'b10000;
  localparam logic [4:0] FL_DZ = 5'b01000;
  localparam logic [4:0] FL_OF = 5'b00100;
  localparam logic [4:0] FL_UF = 5'b00010;
  localparam logic [4:0] FL_NX = 5'b00001;

  localparam logic [31:0] QNAN = 32'h7fc0_0000;
  localparam logic [31:0] PINF = 32'h7f80_0000;
  localparam logic [31:0] NINF = 32'hff80_0000;

  typedef struct packed {
    logic [31:0] val;
    logic [4:0]  fl;
  } fp_res_t;

  // ---------------------------------------------------------------------------------------------
  // Classification helpers
  // ---------------------------------------------------------------------------------------------
  function automatic bit f_is_nan (logic [31:0] x);  return x[30:23] == 8'hff && x[22:0] != 0;  endfunction
  function automatic bit f_is_snan(logic [31:0] x);  return f_is_nan(x) && !x[22];               endfunction
  function automatic bit f_is_inf (logic [31:0] x);  return x[30:23] == 8'hff && x[22:0] == 0;  endfunction
  function automatic bit f_is_zero(logic [31:0] x);  return x[30:0] == 0;                        endfunction
  function automatic bit f_is_sub (logic [31:0] x);  return x[30:23] == 0 && x[22:0] != 0;      endfunction

  // Position of the most significant set bit, -1 for zero.
  function automatic int msb_idx(wide_t m);
    for (int i = W - 1; i >= 0; i--) begin
      if (m[i]) return i;
    end
    return -1;
  endfunction

  // Unpack a finite non-zero value to magnitude * 2**exp.
  function automatic void f_unpack(logic [31:0] x, output wide_t m, output int e);
    m = '0;
    if (x[30:23] == 0) begin
      m[22:0] = x[22:0];
      e       = -149;
    end else begin
      m[23:0] = {1'b1, x[22:0]};
      e       = int'(x[30:23]) - 150;
    end
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Rounding
  // ---------------------------------------------------------------------------------------------
  // Drop the low `sh` bits of m (shift left when sh <= 0, which is exact) and round the result
  // according to rm. `sticky` stands for non-zero bits below m's LSB. The returned inexact flag is
  // true when any non-zero bit was dropped.
  function automatic wide_t round_shift(wide_t m, int sh, bit sticky, bit sign, rm_e rm, output bit inexact);
    wide_t q;
    bit    guard, rest, inc;
    if (sh <= 0) begin
      q     = m << (-sh);
      guard = 1'b0;
      rest  = sticky;
    end else if (sh > W) begin
      q     = '0;
      guard = 1'b0;
      rest  = (m != 0) || sticky;
    end else begin
      q     = m >> sh;
      guard = m[sh-1];
      rest  = sticky;
      for (int i = 0; i < sh - 1; i++) rest |= m[i];
    end
    inexact = guard | rest;
    case (rm)
      RM_RNE:  inc = guard & (rest | q[0]);
      RM_RTZ:  inc = 1'b0;
      RM_RDN:  inc = sign & inexact;
      RM_RUP:  inc = ~sign & inexact;
      default: inc = guard;           // RM_RMM
    endcase
    return q + wide_t'(inc);
  endfunction

  // Largest finite or infinity: what an overflowing result becomes under each rounding mode.
  function automatic logic [31:0] f_overflow_val(bit sign, rm_e rm);
    bit to_inf;
    case (rm)
      RM_RNE, RM_RMM: to_inf = 1'b1;
      RM_RTZ:         to_inf = 1'b0;
      RM_RDN:         to_inf = sign;
      default:        to_inf = ~sign;  // RM_RUP
    endcase
    return to_inf ? {sign, 8'hff, 23'h0} : {sign, 8'hfe, 23'h7fffff};
  endfunction

  // Round (m + sticky*epsilon) * 2**e to binary32. m must be non-zero.
  function automatic fp_res_t round_pack(bit sign, int e, wide_t m, bit sticky, rm_e rm);
    fp_res_t r;
    int      p, E, Ec, Eu, sh;
    wide_t   q, qu;
    bit      inexact, inexact_u, tiny;
    p  = msb_idx(m);
    E  = p + e;
    r  = '0;

    // Tininess after rounding: round to 24 bits with an unbounded exponent range and look at the
    // exponent of the outcome.
    qu = round_shift(m, p - 23, sticky, sign, rm, inexact_u);
    Eu = (qu[24]) ? E + 1 : E;
    tiny = (Eu < -126);

    // Bounded exponent: subnormals share the minimum exponent.
    Ec = (E < -126) ? -126 : E;
    sh = (Ec - 23) - e;
    q  = round_shift(m, sh, sticky, sign, rm, inexact);
    if (q[24]) begin
      q  = q >> 1;
      Ec = Ec + 1;
    end

    if (Ec + 127 >= 255) begin
      r.val = f_overflow_val(sign, rm);
      r.fl  = FL_OF | FL_NX;
    end else begin
      r.val = {sign, q[23] ? 8'(Ec + 127) : 8'h00, q[22:0]};
      r.fl  = (inexact ? FL_NX : 5'b0) | ((inexact && tiny) ? FL_UF : 5'b0);
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Exact addition of two signed values (sign, magnitude, exponent). Either magnitude can be zero.
  // Returns the sum as sign / magnitude / exponent. A zero sum is reported with m == 0.
  // ---------------------------------------------------------------------------------------------
  function automatic void exact_add(bit sa, wide_t ma, int ea, bit sb, wide_t mb, int eb,
                                    output bit s, output wide_t m, output int e);
    wide_t a, b;
    int    emin;
    if (ma == 0) begin
      s = sb; m = mb; e = eb; return;
    end
    if (mb == 0) begin
      s = sa; m = ma; e = ea; return;
    end
    emin = (ea < eb) ? ea : eb;
    a    = ma << (ea - emin);
    b    = mb << (eb - emin);
    e    = emin;
    if (sa == sb) begin
      s = sa;
      m = a + b;
    end else if (a >= b) begin
      s = sa;
      m = a - b;
    end else begin
      s = sb;
      m = b - a;
    end
  endfunction

  // Sign of an exact zero sum x + y, where x and y are zeros or the exact sum cancelled.
  function automatic bit zero_sum_sign(bit sx, bit sy, rm_e rm);
    if (sx == sy) return sx;
    return (rm == RM_RDN);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Fused multiply-add family:  (neg_p ? -1 : 1) * a * b  +  (neg_c ? -1 : 1) * c
  // This covers fadd (a=x, b=1.0, c=y), fsub, fmul (c=0) and every vfmacc/vfmadd form.
  // ---------------------------------------------------------------------------------------------
  function automatic fp_res_t f_fma(logic [31:0] a, logic [31:0] b, logic [31:0] c, rm_e rm,
                                    bit neg_p = 1'b0, bit neg_c = 1'b0);
    fp_res_t r;
    bit      sp, sc, s;
    wide_t   ma, mb, mc, mp, m;
    int      ea, eb, ec, ep, e;
    bit      p_inf, p_zero, c_inf, c_zero;

    r  = '0;
    sp = a[31] ^ b[31] ^ neg_p;
    sc = c[31] ^ neg_c;

    p_inf  = f_is_inf(a) || f_is_inf(b);
    p_zero = f_is_zero(a) || f_is_zero(b);
    c_inf  = f_is_inf(c);
    c_zero = f_is_zero(c);

    // NaNs, and inf * 0 (invalid even when c is a quiet NaN)
    if (f_is_nan(a) || f_is_nan(b) || f_is_nan(c)) begin
      r.val = QNAN;
      r.fl  = (f_is_snan(a) || f_is_snan(b) || f_is_snan(c) ||
               (p_inf && p_zero && !f_is_nan(a) && !f_is_nan(b))) ? FL_NV : 5'b0;
      return r;
    end
    if (p_inf && p_zero) begin
      r.val = QNAN;
      r.fl  = FL_NV;
      return r;
    end
    if (p_inf || c_inf) begin
      if (p_inf && c_inf && sp != sc) begin
        r.val = QNAN;
        r.fl  = FL_NV;
      end else begin
        r.val = (p_inf ? sp : sc) ? NINF : PINF;
      end
      return r;
    end

    // Finite operands
    if (p_zero) begin
      if (c_zero) begin
        r.val = {zero_sum_sign(sp, sc, rm), 31'b0};
      end else begin
        r.val = {sc, c[30:0]};   // c is exact
      end
      return r;
    end

    f_unpack(a, ma, ea);
    f_unpack(b, mb, eb);
    mp = ma * mb;
    ep = ea + eb;
    if (c_zero) begin
      mc = '0;
      ec = ep;
    end else begin
      f_unpack(c, mc, ec);
    end
    exact_add(sp, mp, ep, sc, mc, ec, s, m, e);
    if (m == 0) begin
      r.val = {zero_sum_sign(sp, sc, rm), 31'b0};
      return r;
    end
    return round_pack(s, e, m, 1'b0, rm);
  endfunction

  function automatic fp_res_t f_add(logic [31:0] a, logic [31:0] b, rm_e rm);
    return f_fma(a, 32'h3f80_0000, b, rm);
  endfunction

  function automatic fp_res_t f_sub(logic [31:0] a, logic [31:0] b, rm_e rm);
    return f_fma(a, 32'h3f80_0000, b, rm, 1'b0, 1'b1);
  endfunction

  function automatic fp_res_t f_mul(logic [31:0] a, logic [31:0] b, rm_e rm);
    // 0 is added with its sign taken from the product so that x*y = +-0 keeps the product sign
    return f_fma(a, b, {a[31] ^ b[31], 31'b0}, rm);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Division
  // ---------------------------------------------------------------------------------------------
  function automatic fp_res_t f_div(logic [31:0] a, logic [31:0] b, rm_e rm);
    fp_res_t r;
    bit      s;
    wide_t   ma, mb, q, rem, num;
    int      ea, eb, la, lb;
    r = '0;
    s = a[31] ^ b[31];
    if (f_is_nan(a) || f_is_nan(b)) begin
      r.val = QNAN;
      r.fl  = (f_is_snan(a) || f_is_snan(b)) ? FL_NV : 5'b0;
      return r;
    end
    if ((f_is_zero(a) && f_is_zero(b)) || (f_is_inf(a) && f_is_inf(b))) begin
      r.val = QNAN;
      r.fl  = FL_NV;
      return r;
    end
    if (f_is_inf(a) || f_is_zero(b)) begin
      r.val = {s, 8'hff, 23'h0};
      r.fl  = (f_is_zero(b) && !f_is_inf(a)) ? FL_DZ : 5'b0;
      return r;
    end
    if (f_is_zero(a) || f_is_inf(b)) begin
      r.val = {s, 31'b0};
      return r;
    end
    f_unpack(a, ma, ea);
    f_unpack(b, mb, eb);
    // Normalise both mantissas to 24 bits so the quotient has 27 or 28 significant bits.
    la = msb_idx(ma);  ma = ma << (23 - la);  ea = ea - (23 - la);
    lb = msb_idx(mb);  mb = mb << (23 - lb);  eb = eb - (23 - lb);
    num = ma << 27;
    q   = num / mb;
    rem = num - q * mb;
    return round_pack(s, ea - eb - 27, q, rem != 0, rm);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Square root
  // ---------------------------------------------------------------------------------------------
  function automatic fp_res_t f_sqrt(logic [31:0] a, rm_e rm);
    fp_res_t r;
    wide_t   m, root, rem, bitv, t;
    int      e, p, k;
    r = '0;
    if (f_is_nan(a)) begin
      r.val = QNAN;
      r.fl  = f_is_snan(a) ? FL_NV : 5'b0;
      return r;
    end
    if (f_is_zero(a)) begin
      r.val = a;   // sqrt(+-0) = +-0
      return r;
    end
    if (a[31]) begin
      r.val = QNAN;
      r.fl  = FL_NV;
      return r;
    end
    if (f_is_inf(a)) begin
      r.val = PINF;
      return r;
    end
    f_unpack(a, m, e);
    // Scale the radicand to about 52 bits with an even exponent: value = m * 2**e, e even.
    p = msb_idx(m);
    k = 52 - p;
    if (((e - k) & 1) != 0) k = k + 1;
    m = m << k;
    e = e - k;
    // Bit-by-bit integer square root of m
    root = '0;
    rem  = m;
    bitv = wide_t'(1) << 54;
    while (bitv > m) bitv = bitv >> 2;
    while (bitv != 0) begin
      t = root + bitv;
      if (rem >= t) begin
        rem  = rem - t;
        root = (root >> 1) + bitv;
      end else begin
        root = root >> 1;
      end
      bitv = bitv >> 2;
    end
    return round_pack(1'b0, e / 2, root, rem != 0, rm);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Comparison, min/max, sign injection, classify
  // ---------------------------------------------------------------------------------------------
  // -1: a < b, 0: equal, 1: a > b. Neither operand may be NaN.
  function automatic int f_cmp(logic [31:0] a, logic [31:0] b);
    if (f_is_zero(a) && f_is_zero(b)) return 0;
    if (a[31] != b[31]) return a[31] ? -1 : 1;
    if (a[30:0] == b[30:0]) return 0;
    if (a[31]) return (a[30:0] > b[30:0]) ? -1 : 1;
    return (a[30:0] > b[30:0]) ? 1 : -1;
  endfunction

  // Quiet comparison (feq): NV only for a signalling NaN.
  function automatic fp_res_t f_eq(logic [31:0] a, logic [31:0] b);
    fp_res_t r;
    r = '0;
    if (f_is_nan(a) || f_is_nan(b)) begin
      r.fl = (f_is_snan(a) || f_is_snan(b)) ? FL_NV : 5'b0;
    end else begin
      r.val = {31'b0, f_cmp(a, b) == 0};
    end
    return r;
  endfunction

  // Signalling comparison (flt, fle): NV for any NaN.
  function automatic fp_res_t f_lt(logic [31:0] a, logic [31:0] b);
    fp_res_t r;
    r = '0;
    if (f_is_nan(a) || f_is_nan(b)) r.fl = FL_NV;
    else                            r.val = {31'b0, f_cmp(a, b) < 0};
    return r;
  endfunction

  function automatic fp_res_t f_le(logic [31:0] a, logic [31:0] b);
    fp_res_t r;
    r = '0;
    if (f_is_nan(a) || f_is_nan(b)) r.fl = FL_NV;
    else                            r.val = {31'b0, f_cmp(a, b) <= 0};
    return r;
  endfunction

  // fmin / fmax: a NaN input yields the other operand, -0 < +0, NV only for signalling NaNs.
  function automatic fp_res_t f_minmax(logic [31:0] a, logic [31:0] b, bit is_max);
    fp_res_t r;
    int      c;
    r = '0;
    r.fl = (f_is_snan(a) || f_is_snan(b)) ? FL_NV : 5'b0;
    if (f_is_nan(a) && f_is_nan(b)) r.val = QNAN;
    else if (f_is_nan(a))           r.val = b;
    else if (f_is_nan(b))           r.val = a;
    else begin
      if (f_is_zero(a) && f_is_zero(b)) begin
        // -0 is the smaller of the two zeros
        if (is_max) r.val = (a[31] && b[31]) ? a : (a[31] ? b : a);
        else        r.val = (a[31] || b[31]) ? (a[31] ? a : b) : a;
      end else begin
        c = f_cmp(a, b);
        if (is_max) r.val = (c >= 0) ? a : b;
        else        r.val = (c <= 0) ? a : b;
      end
    end
    return r;
  endfunction

  // fclass bit mask
  function automatic logic [9:0] f_class(logic [31:0] x);
    logic [9:0] c;
    c = '0;
    if (f_is_nan(x))        begin c[8] = f_is_snan(x) ? 1'b1 : 1'b0; c[9] = ~c[8]; end
    else if (f_is_inf(x))   begin c[x[31] ? 0 : 7] = 1'b1; end
    else if (f_is_zero(x))  begin c[x[31] ? 3 : 4] = 1'b1; end
    else if (f_is_sub(x))   begin c[x[31] ? 2 : 5] = 1'b1; end
    else                    begin c[x[31] ? 1 : 6] = 1'b1; end
    return c;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Conversions
  // ---------------------------------------------------------------------------------------------
  // float -> integer of `bits` width (<= 32), signed or unsigned. Out-of-range, infinite and NaN
  // inputs saturate and raise NV (NaN and +inf give the maximum value, -inf the minimum).
  function automatic fp_res_t f_to_int(logic [31:0] a, rm_e rm, bit is_signed, int bits);
    fp_res_t r;
    wide_t   m, q;
    int      e;
    bit      s, inexact;
    logic [31:0] maxv, minv;
    r = '0;
    if (is_signed) begin
      maxv = (32'd1 << (bits - 1)) - 1;
      minv = -(32'd1 << (bits - 1));
    end else begin
      maxv = (bits == 32) ? 32'hffff_ffff : (32'd1 << bits) - 1;
      minv = 32'd0;
    end
    s = a[31];
    if (f_is_nan(a) || (f_is_inf(a) && !s)) begin
      r.val = maxv;  r.fl = FL_NV;  return r;
    end
    if (f_is_inf(a)) begin
      r.val = minv;  r.fl = FL_NV;  return r;
    end
    if (f_is_zero(a)) return r;
    f_unpack(a, m, e);
    q = round_shift(m, -e, 1'b0, s, rm, inexact);
    // Anything beyond 2**33 is out of range whatever the width; keep the comparison simple
    if (q >= (wide_t'(1) << 33) || msb_idx(q) > 33) begin
      r.val = s ? minv : maxv;  r.fl = FL_NV;  return r;
    end
    if (is_signed) begin
      if (!s && q > wide_t'(maxv))                       begin r.val = maxv; r.fl = FL_NV; return r; end
      if (s  && q > wide_t'(maxv) + wide_t'(1))          begin r.val = minv; r.fl = FL_NV; return r; end
      r.val = s ? 32'(-q[31:0]) : q[31:0];
    end else begin
      if (s && q != 0)                                   begin r.val = minv; r.fl = FL_NV; return r; end
      if (q > wide_t'(maxv))                             begin r.val = maxv; r.fl = FL_NV; return r; end
      r.val = q[31:0];
    end
    // Sign-extension is the caller's business; only the low `bits` bits are meaningful.
    r.fl = inexact ? FL_NX : 5'b0;
    return r;
  endfunction

  // integer (signed or unsigned, `bits` wide) -> float
  function automatic fp_res_t f_from_int(logic [31:0] x, rm_e rm, bit is_signed, int bits);
    wide_t m;
    bit    s;
    logic [31:0] v;
    v = x;
    s = 1'b0;
    if (bits < 32) begin
      if (is_signed) begin
        logic signed [31:0] sx;
        sx = signed'(x << (32 - bits));
        v  = sx >>> (32 - bits);     // arithmetic shift: sign-extends the low `bits` bits
      end
      else           v = x & ((32'd1 << bits) - 1);
    end
    if (is_signed && v[31]) begin
      s = 1'b1;
      v = -v;
    end
    if (v == 0) return '0;
    m = '0;
    m[31:0] = v;
    return round_pack(s, 0, m, 1'b0, rm);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Reciprocal and reciprocal square root estimates, 7 bits of accuracy (RVV spec 13.9, 13.10).
  // The 128-entry tables the spec defines are generated here from the underlying mathematical
  // definition (the estimate of 1/x or 1/sqrt(x) at the centre of each interval, truncated to 7
  // bits); rvv_softfloat_tb checks every entry against the table in the RTL.
  // ---------------------------------------------------------------------------------------------
  // The 128-entry tables of the RVV spec (13.9 vfrec7, 13.10 vfrsqrt7). They are not a plain
  // centre-of-interval formula, so the spec values are listed. softfloat_test checks them against
  // the table in the RTL.
  localparam logic [6:0] REC7_TABLE [128] = '{
    7'd127,
    7'd125,
    7'd123,
    7'd121,
    7'd119,
    7'd117,
    7'd116,
    7'd114,
    7'd112,
    7'd110,
    7'd109,
    7'd107,
    7'd105,
    7'd104,
    7'd102,
    7'd100,
    7'd99,
    7'd97,
    7'd96,
    7'd94,
    7'd93,
    7'd91,
    7'd90,
    7'd88,
    7'd87,
    7'd85,
    7'd84,
    7'd83,
    7'd81,
    7'd80,
    7'd79,
    7'd77,
    7'd76,
    7'd75,
    7'd74,
    7'd72,
    7'd71,
    7'd70,
    7'd69,
    7'd68,
    7'd66,
    7'd65,
    7'd64,
    7'd63,
    7'd62,
    7'd61,
    7'd60,
    7'd59,
    7'd58,
    7'd57,
    7'd56,
    7'd55,
    7'd54,
    7'd53,
    7'd52,
    7'd51,
    7'd50,
    7'd49,
    7'd48,
    7'd47,
    7'd46,
    7'd45,
    7'd44,
    7'd43,
    7'd42,
    7'd41,
    7'd40,
    7'd40,
    7'd39,
    7'd38,
    7'd37,
    7'd36,
    7'd35,
    7'd35,
    7'd34,
    7'd33,
    7'd32,
    7'd31,
    7'd31,
    7'd30,
    7'd29,
    7'd28,
    7'd28,
    7'd27,
    7'd26,
    7'd25,
    7'd25,
    7'd24,
    7'd23,
    7'd23,
    7'd22,
    7'd21,
    7'd21,
    7'd20,
    7'd19,
    7'd19,
    7'd18,
    7'd17,
    7'd17,
    7'd16,
    7'd15,
    7'd15,
    7'd14,
    7'd14,
    7'd13,
    7'd12,
    7'd12,
    7'd11,
    7'd11,
    7'd10,
    7'd9,
    7'd9,
    7'd8,
    7'd8,
    7'd7,
    7'd7,
    7'd6,
    7'd5,
    7'd5,
    7'd4,
    7'd4,
    7'd3,
    7'd3,
    7'd2,
    7'd2,
    7'd1,
    7'd1,
    7'd0
  };
  localparam logic [6:0] RSQRT7_TABLE [128] = '{
    7'd52,
    7'd51,
    7'd50,
    7'd48,
    7'd47,
    7'd46,
    7'd44,
    7'd43,
    7'd42,
    7'd41,
    7'd40,
    7'd39,
    7'd38,
    7'd36,
    7'd35,
    7'd34,
    7'd33,
    7'd32,
    7'd31,
    7'd30,
    7'd30,
    7'd29,
    7'd28,
    7'd27,
    7'd26,
    7'd25,
    7'd24,
    7'd23,
    7'd23,
    7'd22,
    7'd21,
    7'd20,
    7'd19,
    7'd19,
    7'd18,
    7'd17,
    7'd16,
    7'd16,
    7'd15,
    7'd14,
    7'd14,
    7'd13,
    7'd12,
    7'd12,
    7'd11,
    7'd10,
    7'd10,
    7'd9,
    7'd9,
    7'd8,
    7'd7,
    7'd7,
    7'd6,
    7'd6,
    7'd5,
    7'd4,
    7'd4,
    7'd3,
    7'd3,
    7'd2,
    7'd2,
    7'd1,
    7'd1,
    7'd0,
    7'd127,
    7'd125,
    7'd123,
    7'd121,
    7'd119,
    7'd118,
    7'd116,
    7'd114,
    7'd113,
    7'd111,
    7'd109,
    7'd108,
    7'd106,
    7'd105,
    7'd103,
    7'd102,
    7'd100,
    7'd99,
    7'd97,
    7'd96,
    7'd95,
    7'd93,
    7'd92,
    7'd91,
    7'd90,
    7'd88,
    7'd87,
    7'd86,
    7'd85,
    7'd84,
    7'd83,
    7'd82,
    7'd80,
    7'd79,
    7'd78,
    7'd77,
    7'd76,
    7'd75,
    7'd74,
    7'd73,
    7'd72,
    7'd71,
    7'd70,
    7'd70,
    7'd69,
    7'd68,
    7'd67,
    7'd66,
    7'd65,
    7'd64,
    7'd63,
    7'd63,
    7'd62,
    7'd61,
    7'd60,
    7'd59,
    7'd59,
    7'd58,
    7'd57,
    7'd56,
    7'd56,
    7'd55,
    7'd54,
    7'd53
  };

  // idx = frac[22:16] of the (normalised) input.
  function automatic logic [6:0] rec7_table(logic [6:0] idx);
    return REC7_TABLE[idx];
  endfunction

  // idx = {exp[0], frac[22:17]} of the (normalised) input.
  function automatic logic [6:0] rsqrt7_table(logic [6:0] idx);
    return RSQRT7_TABLE[idx];
  endfunction

  // Normalise a finite non-zero input to 1.g * 2**(e_eff - 127): returns the effective biased
  // exponent (<= 0 for subnormals) and the 23-bit fraction g.
  function automatic void f_normalize(logic [31:0] x, output int e_eff, output logic [22:0] g);
    int lz;
    logic [22:0] f;
    if (x[30:23] != 0) begin
      e_eff = int'(x[30:23]);
      g     = x[22:0];
    end else begin
      f = x[22:0];
      lz = 0;
      while (!f[22]) begin f = f << 1; lz++; end
      e_eff = -lz;
      g     = f << 1;     // drop the leading one
    end
  endfunction

  function automatic fp_res_t f_rec7(logic [31:0] a, rm_e rm);
    fp_res_t r;
    int      e_eff, e_out;
    logic [22:0] g;
    logic [22:0] frac;
    r = '0;
    if (f_is_nan(a)) begin
      r.val = QNAN;  r.fl = f_is_snan(a) ? FL_NV : 5'b0;  return r;
    end
    if (f_is_inf(a)) begin
      r.val = {a[31], 31'b0};  return r;
    end
    if (f_is_zero(a)) begin
      r.val = {a[31], 8'hff, 23'b0};  r.fl = FL_DZ;  return r;
    end
    f_normalize(a, e_eff, g);
    e_out = 253 - e_eff;
    frac  = 23'(rec7_table(g[22:16])) << 16;
    if (e_out >= 255) begin
      r.val = f_overflow_val(a[31], rm);
      r.fl  = FL_OF | FL_NX;
    end else if (e_out == 0) begin
      r.val = {a[31], 8'h00, 23'((23'h400000) | (frac >> 1))};
    end else if (e_out == -1) begin
      r.val = {a[31], 8'h00, 23'((23'h200000) | (frac >> 2))};
    end else begin
      r.val = {a[31], 8'(e_out), frac};
    end
    return r;
  endfunction

  function automatic fp_res_t f_rsqrt7(logic [31:0] a);
    fp_res_t r;
    int      e_eff, e_out;
    logic [22:0] g;
    r = '0;
    if (f_is_nan(a)) begin
      r.val = QNAN;  r.fl = f_is_snan(a) ? FL_NV : 5'b0;  return r;
    end
    if (f_is_zero(a)) begin
      r.val = {a[31], 8'hff, 23'b0};  r.fl = FL_DZ;  return r;
    end
    if (a[31]) begin
      r.val = QNAN;  r.fl = FL_NV;  return r;
    end
    if (f_is_inf(a)) begin
      r.val = 32'b0;  return r;
    end
    f_normalize(a, e_eff, g);
    e_out = (380 - e_eff) / 2;
    r.val = {1'b0, 8'(e_out), 23'(rsqrt7_table({e_eff[0], g[22:17]})) << 16};
    return r;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Random operand generation. Uniformly random bit patterns are almost always huge or tiny
  // normal numbers, so operations would overflow/underflow constantly and never exercise
  // cancellation, rounding, subnormals, NaNs or infinities. This mixes all of them.
  // ---------------------------------------------------------------------------------------------
  function automatic logic [31:0] rand_fp32();
    int          k;
    logic [31:0] v;
    logic        s;
    k = $urandom_range(0, 99);
    s = $urandom_range(0, 1);
    if (k < 30) begin
      // moderate magnitude normal: roughly 2**-9 .. 2**9
      v = {s, 8'($urandom_range(118, 136)), 23'($urandom())};
    end else if (k < 42) begin
      // small integer, exactly representable
      v = f_from_int(32'($urandom_range(0, 40)) - 20, RM_RNE, 1'b1, 32).val;
    end else if (k < 50) begin
      // integer + 0.5: exercises every rounding mode when converted or rounded
      v = f_from_int(32'($urandom_range(0, 200)) * 2 - 199, RM_RNE, 1'b1, 32).val;
      v = f_mul(v, 32'h3f00_0000, RM_RNE).val;
    end else if (k < 58) begin
      v = {s, 31'b0};                                              // +-0
    end else if (k < 64) begin
      v = {s, 8'hff, 23'h0};                                       // +-inf
    end else if (k < 70) begin
      // NaN, quiet or signalling, random payload (a signalling NaN needs a non-zero payload)
      v = {s, 8'hff, 23'($urandom())};
      if (v[22:0] == 0) v[0] = 1'b1;
    end else if (k < 78) begin
      v = {s, 8'h00, 23'($urandom())};                             // subnormal (or zero)
    end else if (k < 82) begin
      v = {s, 8'($urandom_range(1, 2)), 23'($urandom())};          // smallest normals
    end else if (k < 86) begin
      v = {s, 8'($urandom_range(253, 254)), 23'($urandom())};      // largest normals
    end else if (k < 90) begin
      v = {s, 8'h7f, 23'h0};                                       // +-1.0
    end else begin
      v = $urandom();                                              // anything
    end
    return v;
  endfunction

endpackage: rvv_softfloat_pkg

`endif // RVV_SOFTFLOAT__SVH
