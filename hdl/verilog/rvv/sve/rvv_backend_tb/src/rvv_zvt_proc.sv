`ifndef RVV_ZVT_PROC
`define RVV_ZVT_PROC

//------------------------------------------------------------------------------
// CLASS: zvt_processor
//
// Executes one Zvt instruction on the reference model: the tile state lives here, the vector
// register file in the model. All arithmetic and addressing is rvv_zvt_pkg, i.e. the spec.
//------------------------------------------------------------------------------
class zvt_processor;
  rvv_zvt_pkg::zvt_tiles tiles;
  logic [4:0]            flags;      // fflags the last instruction raised

  // Snapshot of the destination tile of the last instruction, for the scoreboard. A tile occupies whole
  // byte-granular tiles (dst_ptile .. dst_ptile+dst_nptile-1); dst_val holds all their bytes after the
  // instruction, dst_req flags the bytes the instruction wrote (body, and tail under the all-ones
  // policy). The other bytes must be unchanged. dst_nptile is 0 when no tile is written (vtse, vtmv.v.t).
  int unsigned           dst_ptile;
  int unsigned           dst_nptile;
  byte unsigned          dst_val [];
  bit                    dst_req [];

  function new();
    tiles = new();
  endfunction

  function void snapshot(int unsigned tile, int unsigned tew);
    dst_ptile  = tile;
    dst_nptile = rvv_zvt_pkg::zvt_tile_nptiles(tew);
    dst_val    = new[dst_nptile * rvv_zvt_pkg::TILE_BYTES];
    dst_req    = new[dst_nptile * rvv_zvt_pkg::TILE_BYTES];
    foreach(dst_val[i]) begin
      dst_val[i] = tiles.mem[dst_ptile * rvv_zvt_pkg::TILE_BYTES + i];
      dst_req[i] = tiles.touched[dst_ptile * rvv_zvt_pkg::TILE_BYTES + i];
    end
  endfunction

  function void no_snapshot();
    dst_nptile = 0;
    dst_val.delete();
    dst_req.delete();
  endfunction

  // Run `t` against the current architectural state of `rvm`. The vector register file of the model
  // is only read; vector results go into rvm.vrf_temp through elm_writeback.
  function void exe(rvv_behavior_model rvm, rvs_transaction t);
    int unsigned sew, twiden, tew, tn, kmax, tile, row, col;
    rvv_zvt_pkg::zvt_tss_t tss;
    sew    = 8 << t.vsew;
    twiden = rvv_zvt_pkg::zvt_twiden(t.mtwiden);
    tew    = sew * twiden;
    kmax   = rvv_zvt_pkg::zvt_kmax(sew, twiden);
    tiles.clear_touched();
    flags = '0;

    case(t.alu_inst)
      VTZERO: begin
        // TEW = SEW * TWIDEN, the accumulator width (the RTL agrees: eew_mt from {SEW, mtwiden})
        tile = t.dest_idx[4:1];
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, tew);
        rvv_zvt_pkg::zvt_vtzero(tiles, tile, tew, t.tm, tn);
        if(rvv_zvt_pkg::TILE_TAIL_POLICY_ZERO == rvv_zvt_pkg::TILE_TAIL_ALL_ONES)
          rvv_zvt_pkg::zvt_tail_ones_submatrix(tiles, tile, tew, t.tm, tn);
        snapshot(tile, tew);
      end

      VTMMU, VTMMS: begin
        // A[k][m]: element m of the vs2 row group k; B[k][n]: element n of the vs1 row group k.
        // Successive rows are 8/KMAX registers apart.
        byte unsigned a [4][rvv_zvt_pkg::TE];
        byte unsigned b [4][rvv_zvt_pkg::TE];
        tile = t.dest_idx[4:1];
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, tew);
        for(int k = 0; k < 4; k++) begin
          for(int i = 0; i < rvv_zvt_pkg::TE; i++) begin
            a[k][i] = 0;
            b[k][i] = 0;
            if(k < t.tk) begin
              a[k][i] = rvm.elm_fetch(VRF, t.src2_idx + k * (8 / kmax), i, 8);
              b[k][i] = rvm.elm_fetch(VRF, t.src1_idx + k * (8 / kmax), i, 8);
            end
          end
        end
        rvv_zvt_pkg::zvt_mm_int(tiles, tile, t.tm, tn, t.tk, a, b, (t.alu_inst == VTMMS), t.altfmt);
        mm_tail(tile, tew, t.tm, tn, t.tk);
        snapshot(tile, tew);
      end

      VTFMM: begin
        logic [31:0] a [rvv_zvt_pkg::TE];
        logic [31:0] b [rvv_zvt_pkg::TE];
        tile = t.dest_idx[4:1];
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, tew);
        for(int i = 0; i < rvv_zvt_pkg::TE; i++) begin
          a[i] = rvm.elm_fetch(VRF, t.src2_idx, i, 32);
          b[i] = rvm.elm_fetch(VRF, t.src1_idx, i, 32);
        end
        if(uvm_report_enabled(UVM_HIGH, UVM_INFO, "MDL")) begin
          // per-element trace (+UVM_VERBOSITY=UVM_HIGH): tm*tn lines per vtfmm, so only built when enabled
          logic [31:0] cold [rvv_zvt_pkg::TE][rvv_zvt_pkg::TE];
          for(int m = 0; m < t.tm; m++) for(int n = 0; n < tn; n++) cold[m][n] = tiles.get(tile, m, n, 32)[31:0];
          flags = rvv_zvt_pkg::zvt_mm_fp32(tiles, tile, t.tm, tn, t.tk, a, b, rvv_softfloat_pkg::rm_e'(t.frm[2:0]));
          for(int m = 0; m < t.tm; m++) for(int n = 0; n < tn; n++)
            `uvm_info("MDL", $sformatf("vtfmm pc=0x%0x frm=%0d C[%0d][%0d] off=0x%03x: a=%08x b=%08x cold=%08x -> %08x", t.pc, t.frm, m, n,
                                         rvv_zvt_pkg::zvt_punning(tile, m, n, 32) % rvv_zvt_pkg::TILE_BYTES, a[m], b[n], cold[m][n], tiles.get(tile, m, n, 32)[31:0]), UVM_HIGH)
        end else begin
          flags = rvv_zvt_pkg::zvt_mm_fp32(tiles, tile, t.tm, tn, t.tk, a, b, rvv_softfloat_pkg::rm_e'(t.frm[2:0]));
        end
        mm_tail(tile, tew, t.tm, tn, t.tk);
        snapshot(tile, tew);
      end

      VTMV_T_V: begin
        // tile subset <- vs2, TEW = SEW
        tss  = rvv_zvt_pkg::zvt_tss_decode(t.rs1_data);
        tile = rvv_zvt_pkg::zvt_tile_num(tss.tile, sew);
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, sew);
        for(int i = t.vstart; i < tn; i++) begin
          rvv_zvt_pkg::zvt_tss_coord(tss, i, row, col);
          tiles.set(tile, row, col, sew, 64'(rvm.elm_fetch(VRF, t.src2_idx, i, sew)));
        end
        tss_tail(rvv_zvt_pkg::TILE_TAIL_POLICY_MV, tss, tile, sew, t.vstart, tn);
        snapshot(tile, sew);
      end

      VTMV_V_T: begin
        // vd <- tile subset, TEW = SEW. Elements past the body are vector tail (agnostic).
        tss  = rvv_zvt_pkg::zvt_tss_decode(t.rs1_data);
        tile = rvv_zvt_pkg::zvt_tile_num(tss.tile, sew);
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, sew);
        for(int i = t.vstart; i < tn; i++) begin
          logic [63:0] v;
          rvv_zvt_pkg::zvt_tss_coord(tss, i, row, col);
          v = tiles.get(tile, row, col, sew);
          rvm.elm_writeback(v[31:0], VRF, t.dest_idx, i, sew);
        end
        if(rvm.all_one_for_agn) begin
          for(int i = tn; i < t.vlmax; i++) rvm.elm_writeback('1, VRF, t.dest_idx, i, sew);
        end
        no_snapshot();
      end

      VTLE, VTSE: begin
        // Tile subset <-> contiguous memory, TEW = EEW (static in the encoding). Body elements
        // [vstart, min(vl, ETE) - 1], element i at base + i * EEW/8, ascending; no memory is
        // accessed for the other elements.
        int unsigned ew, eb;
        ew   = t.zt_ew;
        eb   = ew / 8;
        tss  = rvv_zvt_pkg::zvt_tss_decode(t.rs1_data);
        tile = rvv_zvt_pkg::zvt_tile_num(tss.tile, ew);
        tn   = rvv_zvt_pkg::zvt_body_end(t.vl, ew);
        rvm.mem.pc = t.pc;
        for(int i = t.vstart; i < tn; i++) begin
          logic [63:0] v;
          rvv_zvt_pkg::zvt_tss_coord(tss, i, row, col);
          if(t.alu_inst == VTLE) begin
            v = '0;
            for(int b = 0; b < eb; b++) begin
              logic [7:0] d;
              rvm.mem.load_byte(d, t.zt_base + i * eb + b);
              v[b*8 +: 8] = d;
            end
            tiles.set(tile, row, col, ew, v);
          end else begin
            v = tiles.get(tile, row, col, ew);
            for(int b = 0; b < eb; b++) rvm.mem.store_byte(v[b*8 +: 8], t.zt_base + i * eb + b);
          end
        end
        if(t.alu_inst == VTLE) begin
          tss_tail(rvv_zvt_pkg::TILE_TAIL_POLICY_LD, tss, tile, ew, t.vstart, tn);
          snapshot(tile, ew);
        end else begin
          no_snapshot();
        end
      end

      default: begin
        `uvm_error("MDL/ZVT", $sformatf("pc=0x%8x: %s is not implemented in the model yet", t.pc, t.alu_inst.name()))
        no_snapshot();
      end
    endcase
  endfunction

  // Matmul tail: elements of mtd outside [0,tm-1] x [0,tn-1]. When tm, tn or tk is zero nothing is
  // computed and no state is updated, the tail included.
  function void mm_tail(int unsigned tile, int unsigned tew, int unsigned tm, int unsigned tn, int unsigned tk);
    if(tm == 0 || tn == 0 || tk == 0) return;
    if(rvv_zvt_pkg::TILE_TAIL_POLICY_MM == rvv_zvt_pkg::TILE_TAIL_ALL_ONES)
      rvv_zvt_pkg::zvt_tail_ones_submatrix(tiles, tile, tew, tm, tn);
  endfunction

  // Tile subset tail: elements [min(vl, ETE), ETE-1]. As in RVV, when vstart >= the end of the body
  // no element is updated, the tail included.
  function void tss_tail(rvv_zvt_pkg::tile_tail_policy_e pol, rvv_zvt_pkg::zvt_tss_t tss, int unsigned tile,
                         int unsigned tew, int unsigned vstart, int unsigned body_end);
    if(vstart >= body_end) return;
    if(pol == rvv_zvt_pkg::TILE_TAIL_ALL_ONES)
      rvv_zvt_pkg::zvt_tail_ones_tss(tiles, tss, tile, tew, body_end);
  endfunction
endclass: zvt_processor

`endif // RVV_ZVT_PROC
