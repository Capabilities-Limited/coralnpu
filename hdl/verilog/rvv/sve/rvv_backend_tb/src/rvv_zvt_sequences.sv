`ifndef RVV_ZVT_SEQUENCES__SV
`define RVV_ZVT_SEQUENCES__SV

//===========================================================
// Zvt (matrix extension) instruction sequences
//
// Zvt instructions are not randomised by the solver: each one is built by rvs_transaction::zvt_build
// under a configuration that msetmtype / msettn / msettm / msettk could have produced. Instructions
// that retire through vmeRt and ones that retire through the ROB are separated by a fence (the
// driver waits for the backend to go idle), so the two retire paths never reorder.
//===========================================================
class zvt_seq extends base_sequence;
  `uvm_object_utils(zvt_seq)
  `uvm_add_to_seq_lib(zvt_seq,rvs_sequencer_sequence_library)

  localparam int TE = rvv_zvt_pkg::TE;

  // 0 none yet, 1 retires through vmeRt, 2 through the ROB
  static int unsigned last_path = 0;

  int unsigned inst_num = 100;
  // 0: random mix, 1: FP32 matmul sweep over tm / tn, 2: int8 matmul sweep over tm / tn / tk,
  // 3: one FP32 matmul from plusargs, 4: tile load / store sweep over EEW / pattern
  int          mode     = 0;
  bit          use_fp   = 0;   // include the FP32 matmul

  function new(string name = "zvt_seq");
    super.new(name);
    `ifdef UVM_POST_VERSION_1_1
      set_automatic_phase_objection(1);
    `endif
  endfunction: new

  // (sew, mtwiden) pairs the spec allows with ELEN=32
  function void pick_cfg(output int sew, output int mtw);
    int r;
    r = $urandom_range(0, 5);
    case(r)
      0: begin sew = 8;  mtw = 1; end
      1: begin sew = 8;  mtw = 2; end
      2: begin sew = 8;  mtw = 3; end
      3: begin sew = 16; mtw = 1; end
      4: begin sew = 16; mtw = 2; end
      default: begin sew = 32; mtw = 1; end
    endcase
  endfunction

  // Send one built instruction, fencing when the retire path changes
  task send(rvs_transaction t);
    int unsigned path;
    path = t.is_zvt_vme ? 1 : 2;
    // +zvt_fence_all serialises every instruction (debug: separates ordering effects from data effects)
    t.fence_before = (last_path != 0 && path != last_path) || $test$plusargs("zvt_fence_all");
    last_path = path;
    start_item(t);
    t.pc = inst_cnt;
    finish_item(t);
    inst_cnt++;
  endtask

  // A register that is a multiple of `align`, and below `lim` modulo 8
  function int pick_reg(int align, int lim_mod8);
    int r;
    forever begin
      r = $urandom_range(0, 31);
      if(r % align == 0 && (r % 8) < lim_mod8) return r;
    end
  endfunction

  // A tile number at `tew`: any multiple of 16/NTiles
  function int pick_tile(int tew);
    int step;
    step = 16 / rvv_zvt_pkg::zvt_ntiles(tew);
    return $urandom_range(0, rvv_zvt_pkg::zvt_ntiles(tew) - 1) * step;
  endfunction

  // vtzero of the whole matrix state: zero every TEW=32 tile completely
  task zero_all();
    for(int t = 0; t < 16; t += 4) begin
      rvs_transaction r;
      r = new("zero");
      r.zvt_build(VTZERO, 8, 3, TE, TE, 4, 0, t, 0, 0, 0, 0);
      send(r);
    end
  endtask

  task one_zero();
    rvs_transaction r; int sew, mtw, tew, tm, tn;
    pick_cfg(sew, mtw);
    tew = sew * (1 << (mtw - 1));
    tm = $urandom_range(1, TE); tn = $urandom_range(1, TE);
    r = new("vtzero");
    r.zvt_build(VTZERO, sew, mtw, tm, tn, 1, 0, pick_tile(tew), 0, 0, 0, 0);
    send(r);
  endtask

  // vtmv.t.v of a random vector register into a random row / column
  task one_mv_t_v();
    rvs_transaction r; int sew, mtw, vl, vs;
    rvv_zvt_pkg::zvt_cfg_t c;
    pick_cfg(sew, mtw);
    c = rvv_zvt_pkg::zvt_msetmtype(sew, mtw, TE, 1, 0);
    vl = $urandom_range(1, TE);
    vs = pick_reg(c.lmul, 8);
    r = new("vtmv.t.v");
    r.zvt_build(VTMV_T_V, sew, mtw, TE, vl, 1, 0, $urandom_range(0, 15), vs, 0, $urandom_range(0, 1),
                $urandom_range(0, TE - 1), $urandom_range(0, vl - 1));
    send(r);
  endtask

  task one_mv_v_t();
    rvs_transaction r; int sew, mtw, vl, vd;
    rvv_zvt_pkg::zvt_cfg_t c;
    pick_cfg(sew, mtw);
    c = rvv_zvt_pkg::zvt_msetmtype(sew, mtw, TE, 1, 0);
    vl = $urandom_range(1, TE);
    vd = pick_reg(c.lmul, 8);
    r = new("vtmv.v.t");
    r.zvt_build(VTMV_V_T, sew, mtw, TE, vl, 1, 0, $urandom_range(0, 15), vd, 0, $urandom_range(0, 1),
                $urandom_range(0, TE - 1), $urandom_range(0, vl - 1));
    send(r);
  endtask

  // Tile loads / stores address [MEM_LO, MEM_HI); the test fills that range (zvt_basic_test::configure_phase)
  localparam int unsigned MEM_LO = 32'h0000;
  localparam int unsigned MEM_HI = 32'h2000;

  // vtle / vtse of a random tile subset: EEW 8/16/32 (TEW = EEW), row or column, any vl and a vstart
  // inside the body, naturally aligned base. The vtype comes from a random legal msetmtype.
  task one_ldst(alu_inst_e op, int ew = 0, int pattern = -1);
    rvs_transaction r; int sew, mtw, vl, ete, evl, vstart;
    logic [31:0] base;
    if(ew == 0) ew = 8 << $urandom_range(0, 2);
    if(pattern < 0) pattern = $urandom_range(0, 1);
    pick_cfg(sew, mtw);
    ete = rvv_zvt_pkg::zvt_ete(ew);
    vl  = $urandom_range(1, TE);
    r = new(op == VTLE ? "vtle" : "vtse");
    // msettn may clip vl; build once to learn the real vl, then pick vstart inside the body
    r.zvt_build(op, sew, mtw, TE, vl, 1, 0, 0, 0, 0, pattern, 0, 0, 5, 0, ew);
    evl    = (r.vl < ete) ? r.vl : ete;
    vstart = ($urandom_range(0, 3) == 0) ? $urandom_range(0, evl - 1) : 0;
    base   = MEM_LO + ($urandom_range(0, (MEM_HI - MEM_LO - ete * ew / 8) / (ew / 8)) * (ew / 8));
    r.zvt_build(op, sew, mtw, TE, vl, 1, 0, $urandom_range(0, 15), 0, 0, pattern,
                $urandom_range(0, ete - 1), vstart, 5, base, ew);
    send(r);
  endtask

  // Every EEW x pattern, random vl / vstart / tile subset / address: loads (checked through the tile
  // retire record) interleaved with stores (checked through the memory access stream).
  task ldst_sweep();
    zero_all();
    for(int e = 0; e < 3; e++) begin
      for(int p = 0; p < 2; p++) begin
        repeat(inst_num / 6 + 1) begin
          one_ldst(VTLE, 8 << e, p);
          one_ldst(VTSE, 8 << e, p);
        end
      end
    end
  endtask

  // int8 matmul, vs2 / vs1 rows 8/KMAX = 2 registers apart, so the base is 0 or 1 modulo 8
  task one_mm_int();
    rvs_transaction r; int tm, tn, tk;
    alu_inst_e op;
    tm = $urandom_range(1, TE); tn = $urandom_range(1, TE); tk = $urandom_range(1, 4);
    op = ($urandom_range(0, 1)) ? VTMMS : VTMMU;
    r = new("vtmm");
    r.zvt_build(op, 8, 3, tm, tn, tk, $urandom_range(0, 1), pick_tile(32), pick_reg(1, 2), pick_reg(1, 2), 0, 0);
    send(r);
  endtask

  // FP32 matmul: KMAX=1, LMUL=4 so the operands are LMUL4 aligned
  task one_mm_fp();
    rvs_transaction r; int tm, tn;
    tm = $urandom_range(1, TE); tn = $urandom_range(1, TE);
    r = new("vtfmm");
    r.zvt_build(VTFMM, 32, 1, tm, tn, 1, 0, pick_tile(32), pick_reg(4, 8), pick_reg(4, 8), 0, 0);
    send(r);
  endtask

  // One matmul per (tm, tn), each on a freshly zeroed tile so a mismatch cannot cascade.
  task sweep();
    int tns[4] = '{1, 5, 9, TE};
    int tm_max = TE;
    void'($value$plusargs("zvt_sweep_tm_max=%d", tm_max));   // debug: shorten the sweep
    for(int tm = 1; tm <= tm_max; tm++) begin
      foreach(tns[i]) begin
        rvs_transaction z, r;
        z = new("zero");
        z.zvt_build(VTZERO, 8, 3, TE, TE, 4, 0, 0, 0, 0, 0, 0);
        send(z);
        r = new("sweep");
        if(mode == 1) begin
          r.zvt_build(VTFMM, 32, 1, tm, tns[i], 1, 0, 0, 8, 12, 0, 0);
          send(r);
          // +zvt_readback: read every result row back through the vector registers, so the
          // architectural tile is checked as well as the retire-time snapshot
          if($test$plusargs("zvt_readback")) begin
            for(int row = 0; row < tm; row++) begin
              rvs_transaction rb;
              rb = new("readback");
              rb.zvt_build(VTMV_V_T, 32, 1, TE, TE, 1, 0, 0, 16, 0, 0, row);
              send(rb);
            end
          end
        end else begin
          for(int tk = 1; tk <= 4; tk += 3) begin
            r = new("sweep");
            r.zvt_build(VTMMS, 8, 3, tm, tns[i], tk, 0, 0, 8, 9, 0, 0);
            send(r);
          end
        end
      end
    end
  endtask

  // One FP32 matmul on a zeroed tile with the operands and dimensions given by plusargs
  //   +zvt_tm=N +zvt_tn=N +zvt_vs2=N +zvt_vs1=N +zvt_tile=N
  task single();
    rvs_transaction z, r;
    int tm, tn, vs2, vs1, tile;
    tm = 16; tn = 16; vs2 = 8; vs1 = 12; tile = 0;
    void'($value$plusargs("zvt_tm=%d", tm));
    void'($value$plusargs("zvt_tn=%d", tn));
    void'($value$plusargs("zvt_vs2=%d", vs2));
    void'($value$plusargs("zvt_vs1=%d", vs1));
    void'($value$plusargs("zvt_tile=%d", tile));
    z = new("zero");
    z.zvt_build(VTZERO, 8, 3, TE, TE, 4, 0, tile, 0, 0, 0, 0);
    send(z);
    r = new("single");
    r.zvt_build(VTFMM, 32, 1, tm, tn, 1, 0, tile, vs2, vs1, 0, 0);
    send(r);
  endtask

  virtual task body();
    if(mode == 3) begin single(); return; end
    if(mode == 4) begin ldst_sweep(); return; end
    if(mode != 0) begin sweep(); return; end
    zero_all();
    repeat(inst_num) begin
      int r;
      r = $urandom_range(0, use_fp ? 7 : 6);
      case(r)
        0: one_zero();
        1: one_mv_t_v();
        2: one_mv_v_t();
        3, 4: one_mm_int();
        5: one_ldst(VTLE);
        6: one_ldst(VTSE);
        default: one_mm_fp();
      endcase
    end
  endtask
endclass: zvt_seq

`endif // RVV_ZVT_SEQUENCES__SV
