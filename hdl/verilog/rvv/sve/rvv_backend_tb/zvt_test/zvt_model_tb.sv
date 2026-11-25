// Self-check of rvv_zvt_pkg (include/rvv_zvt_model.svh) against the statements the Zvt 0.4 spec makes
// about tile punning, the configuration instructions and the matmul arithmetic.
`include "rvv_softfloat.svh"
`include "rvv_zvt_model.svh"

module zvt_model_tb;
  import rvv_zvt_pkg::*;
  import rvv_softfloat_pkg::*;

  int errors = 0;
  task automatic fail(string msg);
    errors++;
    if (errors <= 40) $display("FAIL: %s", msg);
  endtask

  // ptiles an element of tile `t` at `tew` can land in
  function automatic int unsigned ptile_mask(int unsigned t, int unsigned tew);
    int unsigned m, ete;
    m = 0; ete = zvt_ete(tew);
    for (int unsigned r = 0; r < ete; r++)
      for (int unsigned c = 0; c < ete; c++)
        m |= 1 << (zvt_punning(t, r, c, tew) / TILE_BYTES);
    return m;
  endfunction

  initial begin
    zvt_tiles s;
    zvt_cfg_t cfg;
    int tews[4] = '{8, 16, 32, 64};
    s = new();

    // 1. Punning is a bijection from (row, col) onto the tile's footprint, for every valid tile
    foreach (tews[i]) begin
      int unsigned tew, ete, nt;
      tew = tews[i]; ete = zvt_ete(tew); nt = zvt_ntiles(tew);
      for (int unsigned t = 0; t < 16; t++) begin
        bit used [STATE_BYTES];
        int unsigned count;
        if (!zvt_tile_valid(t, tew)) continue;
        foreach (used[j]) used[j] = 0;
        count = 0;
        for (int unsigned r = 0; r < ete; r++)
          for (int unsigned c = 0; c < ete; c++) begin
            int unsigned off;
            off = zvt_punning(t, r, c, tew);
            for (int unsigned b = 0; b < tew / 8; b++) begin
              if (off + b >= STATE_BYTES) fail($sformatf("tew=%0d tile=%0d (%0d,%0d) off %0d out of range", tew, t, r, c, off + b));
              else if (used[off + b])     fail($sformatf("tew=%0d tile=%0d (%0d,%0d) overlaps byte %0d", tew, t, r, c, off + b));
              else begin used[off + b] = 1; count++; end
            end
          end
        if (count != ete * ete * tew / 8) fail($sformatf("tew=%0d tile=%0d covers %0d bytes", tew, t, count));
      end
    end

    // 2. The aliasing the spec states: 4 TEW=8 tiles make one TEW=32 tile, mt0 at TEW=32 forms
    //    mt0 and mt2 at TEW=16, mt0 at TEW=16 forms mt0 and mt1 at TEW=8, TEW=64 mt0/mt2 from TEW=32 mt0.
    if (ptile_mask(0, 32) !== (ptile_mask(0, 8) | ptile_mask(1, 8) | ptile_mask(2, 8) | ptile_mask(3, 8)))
      fail("TEW32 mt0 is not the union of TEW8 mt0..3");
    if (ptile_mask(0, 32) !== (ptile_mask(0, 16) | ptile_mask(2, 16)))
      fail("TEW32 mt0 is not the union of TEW16 mt0 and mt2");
    if (ptile_mask(0, 16) !== (ptile_mask(0, 8) | ptile_mask(1, 8)))
      fail("TEW16 mt0 is not the union of TEW8 mt0 and mt1");
    if (ptile_mask(0, 32) !== (ptile_mask(0, 64) | ptile_mask(2, 64)))
      fail("TEW32 mt0 is not the union of TEW64 mt0 and mt2");
    if (ptile_mask(4, 32) !== (ptile_mask(4, 16) | ptile_mask(6, 16)))
      fail("TEW32 mt4 is not the union of TEW16 mt4 and mt6");

    // 3. Element round trip, and visible aliasing: write a TEW=32 element, read its bytes at TEW=8
    s.set(0, 3, 5, 32, 64'h1122_3344);
    if (s.get(0, 3, 5, 32)[31:0] !== 32'h1122_3344) fail("TEW32 set/get");
    begin
      int unsigned off; off = zvt_punning(0, 3, 5, 32);
      if (s.mem[off] !== 8'h44 || s.mem[off+3] !== 8'h11) fail("little-endian layout");
    end
    s.set(1, 7, 2, 16, 64'hbeef);
    if (s.get(1, 7, 2, 16)[15:0] !== 16'hbeef) fail("TEW16 set/get");

    // 4. Tile specifier
    begin
      zvt_tss_t t;
      t = zvt_tss_decode(zvt_tss_encode(12, 1, 9));
      if (t.tile !== 12 || t.pattern !== 1 || t.index !== 9) fail("TSS round trip");
      if (zvt_tss_reserved(t, 32)) fail("TSS (col 9) should be legal at TE=16");
      t.index = TE;
      if (!zvt_tss_reserved(t, 32)) fail("TSS index ETE is reserved");
      t.index = 3; t.pattern = 2;
      if (!zvt_tss_reserved(t, 32)) fail("TSS pattern 2 is reserved");
      if (zvt_tile_num(5, 32) !== 4 || zvt_tile_num(15, 32) !== 12 || zvt_tile_num(5, 16) !== 4 || zvt_tile_num(5, 8) !== 5)
        fail("tile specifier masking");
    end

    // 5. msetmtype: the spec's lmul formula and clamps (TE=16, VLEN=128)
    if (TE == 16 && VLEN == 128) begin
      cfg = zvt_msetmtype(8, 3, 100, 100, 0);
      if (cfg.lmul !== 1 || cfg.tk !== 4 || cfg.tm !== 16 || cfg.vill || !cfg.vta || !cfg.vma) fail($sformatf("msetmtype e8 w4: lmul=%0d tk=%0d tm=%0d", cfg.lmul, cfg.tk, cfg.tm));
      cfg = zvt_msetmtype(16, 2, 100, 100, 1);
      if (cfg.lmul !== 2 || cfg.tk !== 2 || cfg.tm !== 16) fail($sformatf("msetmtype e16 w2: lmul=%0d tk=%0d tm=%0d", cfg.lmul, cfg.tk, cfg.tm));
      cfg = zvt_msetmtype(32, 1, 100, 100, 0);
      if (cfg.lmul !== 4 || cfg.tk !== 1 || cfg.tm !== 16) fail($sformatf("msetmtype e32 w1: lmul=%0d tk=%0d tm=%0d", cfg.lmul, cfg.tk, cfg.tm));
      cfg = zvt_msetmtype(8, 1, 5, 3, 0);
      if (cfg.tm !== 5 || cfg.tk !== 3) fail("msetmtype keeps in-range tm / tk");
      cfg = zvt_msetmtype(32, 2, 4, 1, 0);   // SEW*TWIDEN = 64 > ELEN: vill
      if (!cfg.vill || cfg.mtwiden !== 0 || cfg.tm !== 0) fail("msetmtype with TEW > ELEN must be vill / unconfigured");
      cfg = zvt_msetmtype(8, 0, 4, 1, 0);
      if (cfg.mtwiden !== 0 || cfg.tm !== 0) fail("mtwiden=0 leaves the matrix unit unconfigured");
      cfg = zvt_msetmtype(8, 3, 16, 4, 0);
      if (zvt_msettn(cfg, 1000) !== 16 || zvt_msettn(cfg, 7) !== 7) fail("msettn");
    end

    // 6. Integer matmul against a brute-force evaluation
    begin
      byte unsigned a [4][TE], b [4][TE];
      longint ref_c [TE][TE];
      zvt_tiles m;
      int unsigned tm, tn, tk;
      m = new();
      tm = 5; tn = 7; tk = 4;
      for (int k = 0; k < 4; k++) for (int i = 0; i < TE; i++) begin a[k][i] = $urandom(); b[k][i] = $urandom(); end
      for (int r = 0; r < TE; r++) for (int c = 0; c < TE; c++) m.set(4, r, c, 32, 64'($urandom()));
      for (int r = 0; r < TE; r++) for (int c = 0; c < TE; c++) ref_c[r][c] = longint'($signed(m.get(4, r, c, 32)[31:0]));
      for (int sa = 0; sa < 2; sa++) for (int sb = 0; sb < 2; sb++) begin
        for (int r = 0; r < tm; r++) for (int c = 0; c < tn; c++)
          for (int k = 0; k < tk; k++)
            ref_c[r][c] += (sa ? longint'($signed(a[k][r])) : longint'(a[k][r])) * (sb ? longint'($signed(b[k][c])) : longint'(b[k][c]));
        zvt_mm_int(m, 4, tm, tn, tk, a, b, sa[0], sb[0]);
      end
      for (int r = 0; r < TE; r++) for (int c = 0; c < TE; c++)
        if (m.get(4, r, c, 32)[31:0] !== ref_c[r][c][31:0]) fail($sformatf("mm_int C[%0d][%0d]", r, c));
    end

    // 7. FP32 matmul: 2*3 + 1 = 7, and only NV / OF may be reported
    begin
      zvt_tiles m; logic [31:0] a [TE], b [TE]; logic [4:0] fl;
      m = new();
      for (int i = 0; i < TE; i++) begin a[i] = 32'h4000_0000; b[i] = 32'h4040_0000; end   // 2.0, 3.0
      for (int r = 0; r < TE; r++) for (int c = 0; c < TE; c++) m.set(0, r, c, 32, 64'h3f80_0000);       // 1.0
      fl = zvt_mm_fp32(m, 0, 3, 2, 1, a, b, RM_RNE);
      if (m.get(0, 1, 1, 32)[31:0] !== 32'h40e0_0000) fail("mm_fp32 2*3+1 != 7");
      if (m.get(0, 3, 0, 32)[31:0] !== 32'h3f80_0000 || m.get(0, 0, 2, 32)[31:0] !== 32'h3f80_0000) fail("mm_fp32 touched the tail");
      if (fl !== 0) fail("mm_fp32 flags");
      a[0] = 32'h7f80_0000; b[0] = 32'h0;   // inf * 0
      fl = zvt_mm_fp32(m, 0, 1, 1, 1, a, b, RM_RNE);
      if (!(fl & FL_NV)) fail("mm_fp32 inf*0 must raise NV");
      a[0] = 32'h7f00_0000; b[0] = 32'h7f00_0000;  // overflow
      fl = zvt_mm_fp32(m, 0, 1, 1, 1, a, b, RM_RNE);
      if (fl !== FL_OF) fail($sformatf("mm_fp32 overflow flags %b (inexact must not be reported)", fl));
    end

    // 8. "If any of [tm, tn, tk] are zero, then no computation is performed and no state is updated."
    begin
      zvt_tiles m; logic [31:0] a [TE], b [TE]; logic [4:0] fl;
      byte unsigned ai [4][TE], bi [4][TE];
      m = new();
      for (int i = 0; i < TE; i++) begin a[i] = 32'h7f80_0000; b[i] = 32'h0; end   // inf * 0: NV if computed
      for (int k = 0; k < 4; k++) for (int i = 0; i < TE; i++) begin ai[k][i] = 8'd3; bi[k][i] = 8'd5; end
      m.clear_touched();
      fl = zvt_mm_fp32(m, 0, 4, 4, 0, a, b, RM_RNE);
      if (fl !== 0 || m.touched_q.size() != 0) fail("mm_fp32 with tk=0 must not compute or update state");
      fl = zvt_mm_fp32(m, 0, 0, 4, 1, a, b, RM_RNE);
      if (fl !== 0 || m.touched_q.size() != 0) fail("mm_fp32 with tm=0 must not compute or update state");
      zvt_mm_int(m, 4, 4, 4, 0, ai, bi, 0, 0);
      zvt_mm_int(m, 4, 4, 0, 4, ai, bi, 0, 0);
      if (m.touched_q.size() != 0) fail("mm_int with tk=0 / tn=0 must not update state");
    end

    // 10. All-ones tails: outside tm x tn for a sub-matrix, past the body for a tile subset
    begin
      zvt_tiles m; zvt_tss_t t; int n_ones;
      m = new();
      m.clear_touched();
      zvt_tail_ones_submatrix(m, 8, 16, 3, 5);   // TEW=16 tile mt8: 2 byte-tiles
      if (m.get(8, 2, 4, 16) !== 0 || m.get(8, 3, 0, 16) !== 64'hffff || m.get(8, 0, 5, 16) !== 64'hffff)
        fail("tail_ones_submatrix boundaries");
      if (m.touched_q.size() != (TE * TE - 15) * 2) fail($sformatf("tail_ones_submatrix wrote %0d bytes", m.touched_q.size()));
      foreach (m.touched_q[i]) if (m.touched_q[i] / TILE_BYTES inside {8, 9} == 0) fail("tail_ones_submatrix left the tile");
      m = new();
      t = zvt_tss_decode(zvt_tss_encode(4, 1, 2));   // column 2 of TEW=32 tile mt4
      zvt_tail_ones_tss(m, t, 4, 32, 6);
      n_ones = 0;
      for (int r = 0; r < TE; r++) if (m.get(4, r, 2, 32) == 64'hffff_ffff) n_ones++;
      if (n_ones != TE - 6 || m.get(4, 5, 2, 32) !== 0 || m.get(4, 6, 3, 32) !== 0) fail("tail_ones_tss");
      if (zvt_tile_nptiles(8) != 1 || zvt_tile_nptiles(16) != 2 || zvt_tile_nptiles(32) != 4 || zvt_tile_nptiles(64) != 2)
        fail("tile_nptiles");
    end

    // 9. TSS bits XLEN-1:31 are reserved
    begin
      zvt_tss_t t;
      t = zvt_tss_decode(32'h8000_0000 | zvt_tss_encode(4, 0, 1));
      if (!zvt_tss_reserved(t, 32)) fail("TSS bit 31 is reserved");
    end

    $display("zvt_model_tb: %0d errors", errors);
    if (errors == 0) $display("zvt_model_tb: PASS"); else $display("zvt_model_tb: FAIL");
    $finish;
  end
endmodule
