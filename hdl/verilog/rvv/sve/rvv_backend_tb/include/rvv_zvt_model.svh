`ifndef RVV_ZVT_MODEL__SVH
`define RVV_ZVT_MODEL__SVH

// Reference model for the Zvt matrix extension, transcribed from the "Zvt Family of Vector Matrix
// Extensions, Version 0.4" draft (riscv-isa-manual PR 2997, src/unpriv/zvt.adoc). It deliberately
// knows nothing about the RTL: where the RTL disagrees with the spec, the RTL is what is wrong.
//
// What is modelled:
//   - the tile state and the tile punning scheme for TEW 8/16/32/64,
//   - the tile subset specifier (TSS),
//   - msetmtype[i] / msettn / msettm / msettk semantics, used to generate legal configurations,
//   - vtzero, vtmv.v.t / vtmv.t.v, vtle / vtse,
//   - the integer matmuls vtmmu / vtmms (SEW=8, TWIDEN=4, Int32 accumulators),
//   - the FP32 matmul vtfmm (SEW=32, TWIDEN=1).
// Not modelled: FP8 / FP16 / BF16 / FP64 matmuls. BF16 and FP16 need the RVBNA bulk-normalised
// accumulation the spec refers to; FP8 and FP64 are separate optional extensions.
//
// Parameters are the implementation's: VLEN, and the tile edge TE (the spec allows any power of two with
// VLEN/4 >= TE >= 4). Both come from the backend's rvv_backend_define.svh (`VLEN, `TE(VLEN)), so the model
// always matches the configuration being built (VLEN_DEFINE).
`include "rvv_backend_define.svh"

// Tile tail policy. Every Zvt instruction that writes the tile state runs with a tail-agnostic policy
// (the matmuls and vtzero say so explicitly; msetmtype forces vta=1 for the moves and loads), and the RVV
// definition of agnostic allows each tail element to be left undisturbed or overwritten with all 1s. The
// model follows one of the two, chosen at compile time per instruction class, as the vector TB does for
// mask tails (RVV_TB_MASK_TAIL_*):
//   0 undisturbed | 1 all_ones
// RVV_TB_TILE_TAIL_MM:   matmuls (vtmmu / vtmms / vtfmm): elements of mtd outside [0,tm-1] x [0,tn-1]
// RVV_TB_TILE_TAIL_ZERO: vtzero: elements of mtd outside [0,tm-1] x [0,tn-1]
// RVV_TB_TILE_TAIL_MV:   vtmv.t.v: tile subset elements [min(vl, ETE), ETE-1]
// RVV_TB_TILE_TAIL_LD:   vtle: tile subset elements [min(vl, ETE), ETE-1]
// Set them with the Makefile's TILE_TAIL / TILE_TAIL_<CLASS> options. Prestart elements (below vstart)
// are always undisturbed. The tail of vtmv.v.t is a vector register tail and follows the vector TB's
// policy (+all_one_for_agn).
`ifndef RVV_TB_TILE_TAIL_MM
  `define RVV_TB_TILE_TAIL_MM 0
`endif
`ifndef RVV_TB_TILE_TAIL_ZERO
  `define RVV_TB_TILE_TAIL_ZERO 0
`endif
`ifndef RVV_TB_TILE_TAIL_MV
  `define RVV_TB_TILE_TAIL_MV 0
`endif
`ifndef RVV_TB_TILE_TAIL_LD
  `define RVV_TB_TILE_TAIL_LD 0
`endif

package rvv_zvt_pkg;
  import rvv_softfloat_pkg::*;

  localparam int unsigned VLEN = `VLEN;
  localparam int unsigned TE   = `TE(`VLEN);
  localparam int unsigned ELEN = 32;
  localparam int unsigned TILE_BYTES = TE * TE;            // one byte-granular tile (TEW=8 view)
  localparam int unsigned STATE_BYTES = 16 * TILE_BYTES;   // the whole matrix state

  typedef enum int unsigned {
    TILE_TAIL_UNDISTURBED = 0,
    TILE_TAIL_ALL_ONES    = 1
  } tile_tail_policy_e;
  localparam tile_tail_policy_e TILE_TAIL_POLICY_MM   = tile_tail_policy_e'(`RVV_TB_TILE_TAIL_MM);
  localparam tile_tail_policy_e TILE_TAIL_POLICY_ZERO = tile_tail_policy_e'(`RVV_TB_TILE_TAIL_ZERO);
  localparam tile_tail_policy_e TILE_TAIL_POLICY_MV   = tile_tail_policy_e'(`RVV_TB_TILE_TAIL_MV);
  localparam tile_tail_policy_e TILE_TAIL_POLICY_LD   = tile_tail_policy_e'(`RVV_TB_TILE_TAIL_LD);

  // ---------------------------------------------------------------------------------------------
  // Dimensions as a function of TEW
  // ---------------------------------------------------------------------------------------------
  // ETE: tile edge in elements
  function automatic int unsigned zvt_ete(int unsigned tew);
    return (tew < 64) ? TE : TE / 2;
  endfunction

  // Number of tiles at this TEW
  function automatic int unsigned zvt_ntiles(int unsigned tew);
    case (tew)
      8:       return 16;
      16:      return 8;
      32:      return 4;
      64:      return 8;
      default: return 0;
    endcase
  endfunction

  // A tile specifier names one of 16 byte-granular tile slots. With fewer tiles the low
  // log2(16/NTiles) bits are ignored. Returns the tile number actually addressed.
  function automatic int unsigned zvt_tile_num(int unsigned tile_field, int unsigned tew);
    int unsigned nt;
    nt = zvt_ntiles(tew);
    if (nt == 0) return 0;
    return tile_field & ~(16 / nt - 1) & 4'hf;
  endfunction

  // A tile at this TEW occupies whole byte-granular tiles: tile, tile+1, ..., tile+16/NTiles-1
  // (from the punning function: TEW=16 adds (row&2)>>1, TEW=32 adds 0..3, TEW=64 adds row/(TE/4)).
  function automatic int unsigned zvt_tile_nptiles(int unsigned tew);
    int unsigned nt;
    nt = zvt_ntiles(tew);
    return (nt == 0) ? 0 : 16 / nt;
  endfunction

  // The spec's instruction-encoding form (vtmm*): a tile number t that is not a multiple of
  // 16/NTiles is reserved.
  function automatic bit zvt_tile_valid(int unsigned t, int unsigned tew);
    int unsigned nt;
    nt = zvt_ntiles(tew);
    return (nt != 0) && (t < 16) && ((t % (16 / nt)) == 0);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Tile punning: the spec's `punning()` pseudocode, verbatim.
  // Returns the byte offset of the element in the linear 16*TE*TE byte buffer.
  // ---------------------------------------------------------------------------------------------
  function automatic int unsigned zvt_punning(int unsigned tile, int unsigned row, int unsigned col,
                                              int unsigned tew);
    int unsigned ptile, minor_offset, major_offset;
    case (tew)
      8: begin
        ptile        = tile;
        minor_offset = (row % 4) * 4 + (col % 4);
        major_offset = (row / 4) * (TE / 4) + (col / 4);
      end
      16: begin
        ptile        = tile + ((row & 2) >> 1);
        minor_offset = (row % 2) * 4 + (col % 2) * 2 + ((col / 2) % 2) * 8;
        major_offset = (row / 4) * (TE / 4) + (col / 4);
      end
      32: begin
        ptile        = tile + 2 * (row / (TE / 2)) + ((col & 2) >> 1);
        minor_offset = (row % 2) * 8 + (col % 2) * 4;
        major_offset = ((row / 2) % (TE / 4)) * (TE / 4) + (col / 4);
      end
      64: begin
        ptile        = tile + (row / (TE / 4));
        minor_offset = (col % 2) * 8;
        major_offset = (row % (TE / 4)) * (TE / 4) + (col / 2);
      end
      default: return 0;
    endcase
    return (ptile * TE * TE) + (major_offset * 16) + minor_offset;
  endfunction

  // Inverse of punning: the (row, col) of the element at byte offset `off` (within the whole state) for
  // tile `tile` at `tew`; returns 0 when the offset is not inside that tile.
  function automatic bit zvt_locate(int unsigned tile, int unsigned tew, int unsigned off,
                                    output int unsigned row, output int unsigned col);
    int unsigned ete;
    ete = zvt_ete(tew);
    for (int unsigned r = 0; r < ete; r++)
      for (int unsigned c = 0; c < ete; c++) begin
        int unsigned o;
        o = zvt_punning(tile, r, c, tew);
        if (off >= o && off < o + tew / 8) begin row = r; col = c; return 1; end
      end
    return 0;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // The matrix tile state
  // ---------------------------------------------------------------------------------------------
  class zvt_tiles;
    byte unsigned mem     [STATE_BYTES];
    bit           touched [STATE_BYTES];   // bytes written by the instruction under evaluation
    int unsigned  touched_q [$];           // the same bytes as a list, in write order

    function new();
      for (int i = 0; i < STATE_BYTES; i++) begin
        mem[i]     = 8'h00;
        touched[i] = 1'b0;
      end
    endfunction

    function void clear_touched();
      foreach (touched_q[i]) touched[touched_q[i]] = 1'b0;
      touched_q.delete();
    endfunction

    // One element, little endian, zero-extended into 64 bits
    function logic [63:0] get(int unsigned tile, int unsigned row, int unsigned col, int unsigned tew);
      int unsigned off;
      logic [63:0] v;
      off = zvt_punning(tile, row, col, tew);
      v   = '0;
      for (int b = 0; b < tew / 8; b++) v[b*8 +: 8] = mem[off + b];
      return v;
    endfunction

    function void set(int unsigned tile, int unsigned row, int unsigned col, int unsigned tew, logic [63:0] v);
      int unsigned off;
      off = zvt_punning(tile, row, col, tew);
      for (int b = 0; b < tew / 8; b++) begin
        mem[off + b] = v[b*8 +: 8];
        if (!touched[off + b]) begin
          touched[off + b] = 1'b1;
          touched_q.push_back(off + b);
        end
      end
    endfunction

    // 16-byte subtile of a byte-granular tile, as the RTL's retire interface names things
    function byte unsigned subtile_byte(int unsigned ptile, int unsigned subtile, int unsigned b);
      return mem[ptile * TILE_BYTES + subtile * 16 + b];
    endfunction
    function bit subtile_touched(int unsigned ptile, int unsigned subtile, int unsigned b);
      return touched[ptile * TILE_BYTES + subtile * 16 + b];
    endfunction
  endclass: zvt_tiles

  // ---------------------------------------------------------------------------------------------
  // Tile subset specifier
  // ---------------------------------------------------------------------------------------------
  typedef struct packed {
    bit          hi;        // bit 31 (XLEN-1:31): reserved
    int unsigned tile;      // bits 30:27, before the TEW-dependent masking
    int unsigned pattern;   // bits 26:24: 0 = row, 1 = column, > 1 reserved
    int unsigned index;     // bits 23:0
  } zvt_tss_t;

  function automatic zvt_tss_t zvt_tss_decode(logic [31:0] tss);
    zvt_tss_t t;
    t.hi      = tss[31];
    t.tile    = tss[30:27];
    t.pattern = tss[26:24];
    t.index   = tss[23:0];
    return t;
  endfunction

  function automatic logic [31:0] zvt_tss_encode(int unsigned tile, int unsigned pattern, int unsigned index);
    logic [31:0] v;
    v = '0;
    v[30:27] = tile[3:0];
    v[26:24] = pattern[2:0];
    v[23:0]  = index[23:0];
    return v;
  endfunction

  // Reserved: any of bits XLEN-1:31 set, pattern > 1, or an index of ETE or more
  function automatic bit zvt_tss_reserved(zvt_tss_t t, int unsigned tew);
    return t.hi || (t.pattern > 1) || (t.index >= zvt_ete(tew));
  endfunction

  // Tile coordinates of element `i` along the pattern
  function automatic void zvt_tss_coord(zvt_tss_t t, int unsigned i, output int unsigned row, output int unsigned col);
    if (t.pattern == 0) begin row = t.index; col = i;       end   // row pattern
    else                begin row = i;       col = t.index; end   // column pattern
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Configuration (msetmtype[i], msettn, msettm, msettk)
  // ---------------------------------------------------------------------------------------------
  // KMAX by SEW and TWIDEN, 0 for a combination the spec does not define
  function automatic int unsigned zvt_kmax(int unsigned sew, int unsigned twiden);
    case ({sew[7:0], twiden[3:0]})
      {8'd8,  4'd1}: return 4;
      {8'd8,  4'd2}: return 4;
      {8'd16, 4'd1}: return 2;
      {8'd8,  4'd4}: return 4;
      {8'd16, 4'd2}: return 2;
      {8'd32, 4'd1}: return 1;
      {8'd16, 4'd4}: return 2;
      {8'd32, 4'd2}: return 1;
      {8'd64, 4'd1}: return 1;
      default:       return 0;
    endcase
  endfunction

  typedef struct packed {
    bit          vill;      // the resulting configuration is invalid (mtype and vtype read as 0 / vill)
    int unsigned vl;        // = tn, 0 straight after msetmtype
    int unsigned lmul;      // vtype.vlmul as a register count (1, 2, 4, 8)
    int unsigned sew;
    int unsigned mtwiden;   // 0: matrix unit not configured
    int unsigned tm;
    int unsigned tk;
    bit          altfmt;
    bit          vta;       // forced to 1 when mtwiden != 0
    bit          vma;
  } zvt_cfg_t;

  function automatic int unsigned zvt_twiden(int unsigned mtwiden);
    return (mtwiden == 0) ? 0 : (1 << (mtwiden - 1));
  endfunction

  // msetmtype[i] with the spec's pseudocode. `tm_req`/`tk_req` are the requested mtype.tm / mtype.tk.
  function automatic zvt_cfg_t zvt_msetmtype(int unsigned sew, int unsigned mtwiden, int unsigned tm_req,
                                            int unsigned tk_req, bit altfmt);
    zvt_cfg_t c;
    int unsigned twiden, tew, ete, eve, kmax, m1, m2, m3, lmul;
    c = '0;
    c.sew     = sew;
    c.mtwiden = mtwiden;
    c.altfmt  = altfmt;
    c.vl      = 0;
    if (mtwiden == 0) return c;                 // not configured: mtype reads 0
    twiden = zvt_twiden(mtwiden);
    tew    = sew * twiden;
    ete    = (tew < 64) ? TE : TE / 2;
    eve    = VLEN / sew;
    kmax   = zvt_kmax(sew, twiden);
    // vlmul = log2(min(8/KMAX, 8/TWIDEN, ceil(ETE/EVE)))
    m1 = (kmax == 0) ? 8 : 8 / kmax;
    m2 = 8 / twiden;
    m3 = (ete + eve - 1) / eve;
    lmul = m1;
    if (m2 < lmul) lmul = m2;
    if (m3 < lmul) lmul = m3;
    c.lmul = lmul;
    c.vta  = 1'b1;
    c.vma  = 1'b1;
    c.vill = (sew * twiden > ELEN);
    c.tk   = (tk_req < kmax) ? tk_req : kmax;
    c.tm   = tm_req;
    if (lmul * eve < c.tm) c.tm = lmul * eve;
    if (ete < c.tm)        c.tm = ete;
    if (c.vill) begin
      c.mtwiden = 0; c.tm = 0; c.tk = 0; c.lmul = 0; c.altfmt = 0;
    end
    return c;
  endfunction

  // msettn: rd = vl = min(rs1, LMUL*EVE, ETE) when configured
  function automatic int unsigned zvt_msettn(zvt_cfg_t c, int unsigned rs1);
    int unsigned twiden, tew, ete, eve, v;
    twiden = zvt_twiden(c.mtwiden);
    tew    = c.sew * twiden;
    ete    = (tew < 64) ? TE : TE / 2;
    eve    = VLEN / c.sew;
    v = rs1;
    if (c.lmul * eve < v) v = c.lmul * eve;
    if (ete < v)          v = ete;
    return v;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Operations
  // ---------------------------------------------------------------------------------------------
  // vtzero: zero the tm x tn sub-matrix of the destination tile; TEW = SEW * TWIDEN (the accumulator
  // width; the spec says only that all TEWs from 8 to ELEN are supported).
  function automatic void zvt_vtzero(zvt_tiles s, int unsigned tile, int unsigned tew,
                                     int unsigned tm, int unsigned tn);
    for (int unsigned r = 0; r < tm; r++)
      for (int unsigned c = 0; c < tn; c++)
        s.set(tile, r, c, tew, '0);
  endfunction

  // Elements [vstart, min(vl, ETE) - 1] are the body of the tile moves and loads / stores
  function automatic int unsigned zvt_body_end(int unsigned vl, int unsigned tew);
    int unsigned ete;
    ete = zvt_ete(tew);
    return (vl < ete) ? vl : ete;     // exclusive upper bound
  endfunction

  // Tail of a tm x tn sub-matrix operation (matmuls, vtzero) under the all-ones agnostic policy: every
  // element of the ETE x ETE tile outside [0,tm-1] x [0,tn-1] is overwritten with 1s.
  function automatic void zvt_tail_ones_submatrix(zvt_tiles s, int unsigned tile, int unsigned tew,
                                                  int unsigned tm, int unsigned tn);
    int unsigned ete;
    ete = zvt_ete(tew);
    for (int unsigned r = 0; r < ete; r++)
      for (int unsigned c = 0; c < ete; c++)
        if (r >= tm || c >= tn) s.set(tile, r, c, tew, '1);
  endfunction

  // Tail of a tile subset access (vtmv.t.v, vtle) under the all-ones agnostic policy: elements
  // [body_end, ETE-1] along the pattern are overwritten with 1s.
  function automatic void zvt_tail_ones_tss(zvt_tiles s, zvt_tss_t t, int unsigned tile, int unsigned tew,
                                            int unsigned body_end);
    int unsigned row, col;
    for (int unsigned i = body_end; i < zvt_ete(tew); i++) begin
      zvt_tss_coord(t, i, row, col);
      s.set(tile, row, col, tew, '1);
    end
  endfunction

  // Integer matmul: C[m][n] += sum_k A[k][m] * B[k][n], Int32 accumulators (wrap on overflow).
  // a / b hold the raw 8-bit elements, indexed [k][m] and [k][n].
  // "If any of [tm, tn, tk] are zero, then no computation is performed and no state is updated."
  function automatic void zvt_mm_int(zvt_tiles s, int unsigned tile, int unsigned tm, int unsigned tn,
                                     int unsigned tk, byte unsigned a [4][TE], byte unsigned b [4][TE],
                                     bit a_signed, bit b_signed);
    if (tm == 0 || tn == 0 || tk == 0) return;
    for (int unsigned m = 0; m < tm; m++) begin
      for (int unsigned n = 0; n < tn; n++) begin
        longint acc;
        acc = longint'($signed(s.get(tile, m, n, 32)[31:0]));
        for (int unsigned k = 0; k < tk; k++) begin
          longint av, bv;
          av = a_signed ? longint'($signed(a[k][m])) : longint'(a[k][m]);
          bv = b_signed ? longint'($signed(b[k][n])) : longint'(b[k][n]);
          acc = acc + av * bv;
        end
        s.set(tile, m, n, 32, 64'(acc[31:0]));
      end
    end
  endfunction

  // FP32 matmul (SEW=32, TWIDEN=1, KMAX=1): each product is computed in IEEE arithmetic and rounded
  // to 32 bits with frm, then added to the accumulator with the same rounding mode. Only the
  // invalid and overflow flags are updated by the matmul instructions.
  // KMAX=1, so tk is 0 (nothing is computed, no state is updated) or 1.
  function automatic logic [4:0] zvt_mm_fp32(zvt_tiles s, int unsigned tile, int unsigned tm, int unsigned tn,
                                             int unsigned tk,
                                             logic [31:0] a [TE], logic [31:0] b [TE], rm_e rm);
    logic [4:0] flags;
    fp_res_t p, r;
    flags = '0;
    if (tm == 0 || tn == 0 || tk == 0) return flags;
    for (int unsigned m = 0; m < tm; m++) begin
      for (int unsigned n = 0; n < tn; n++) begin
        p = f_mul(a[m], b[n], rm);
        r = f_add(s.get(tile, m, n, 32)[31:0], p.val, rm);
        flags |= (p.fl | r.fl) & (FL_NV | FL_OF);
        s.set(tile, m, n, 32, 64'(r.val));
      end
    end
    return flags;
  endfunction

endpackage: rvv_zvt_pkg

`endif // RVV_ZVT_MODEL__SVH
