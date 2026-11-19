`ifndef VME_DRIVER__SV
`define VME_DRIVER__SV

`ifdef ZVT_ON
`uvm_analysis_imp_decl(_vme_inst)

//------------------------------------------------------------------------------
// CLASS: vme_driver
//
// Plays the scalar LSU for Zvt tile loads and stores (vtle / vtse). The backend never sees the
// memory address: it exchanges one VLEN-bit chunk per uop with the LSU, in program order --
// uop_lsu2vme for vtle (memory -> tile), uop_vme2lsu for vtse (tile -> memory). This driver keeps
// the accepted vtle / vtse in program order and, for the oldest, either returns its load data or
// consumes its store data, against the same memory the RVV LSU driver uses.
//
// Uop k carries bytes [k*VLENB, (k+1)*VLENB) of the contiguous memory image starting at the base
// address; element i of the tile subset is bytes [i*EEW/8, (i+1)*EEW/8). Only the body elements
// [vstart, min(vl, ETE)) touch memory (the spec: "No memory is accessed below the elements specified
// by the vstart value"); the other load bytes are driven with random data, so a DUT that writes
// non-body elements into the tile is caught by the tile check.
//------------------------------------------------------------------------------
class vme_driver extends uvm_component;
  typedef virtual vme_interface v_if;
  v_if vme_if;

  uvm_analysis_imp_vme_inst #(rvs_transaction, vme_driver) inst_imp;

  rvv_mem         mem;          // the LSU-side memory (lsu_drv.mem), set by the env
  rvs_transaction ls_q[$];      // accepted vtle / vtse, oldest first
  int unsigned    uop_cnt;      // uops of ls_q[0] already transferred

  // Backpressure / latency knobs (percent)
  int unsigned    st_rdy_pct = 70;
  int unsigned    ld_vld_pct = 70;

  int unsigned    n_vtle, n_vtse;

  `uvm_component_utils(vme_driver)

  function new(string name = "vme_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    inst_imp = new("inst_imp", this);
    void'($value$plusargs("zvt_st_rdy_pct=%d", st_rdy_pct));
    void'($value$plusargs("zvt_ld_vld_pct=%d", ld_vld_pct));
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if(!uvm_config_db#(v_if)::get(this, "", "vme_if", vme_if))
      `uvm_fatal("NO_CONN", "vme_driver: fail to get vme_if")
  endfunction

  function void write_vme_inst(rvs_transaction tr);
    if(tr.is_zvt_inst && tr.alu_inst inside {VTLE, VTSE}) begin
      ls_q.push_back(tr);
      `uvm_info("VME_DRV", $sformatf("queued pc=0x%08x %s (%0d uops)", tr.pc, tr.asm_string, nuops(tr)), UVM_HIGH)
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Geometry of one vtle / vtse
  // ---------------------------------------------------------------------------
  // body elements: [vstart, min(vl, ETE))
  static function int unsigned body_end(rvs_transaction t);
    return rvv_zvt_pkg::zvt_body_end(t.vl, t.zt_ew);
  endfunction

  // number of VLEN-bit uops the backend exchanges for it: enough to cover elements [0, body_end)
  static function int unsigned nuops(rvs_transaction t);
    int unsigned bytes;
    bytes = body_end(t) * t.zt_ew / 8;
    return (bytes + `VLENB(`VLEN) - 1) / `VLENB(`VLEN);
  endfunction

  // is byte b of uop k part of a body element?
  static function bit is_body(rvs_transaction t, int unsigned k, int unsigned b);
    int unsigned e;
    e = (k * `VLENB(`VLEN) + b) / (t.zt_ew / 8);
    return (e >= t.vstart) && (e < body_end(t));
  endfunction

  // ---------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(posedge vme_if.clk);
      if(~vme_if.rst_n) begin
        ls_q.delete();
        uop_cnt = 0;
        vme_if.uop_lsu2vme_vld <= 1'b0;
        vme_if.uop_vme2lsu_rdy <= 1'b1;
      end else begin
        bit ld_taken;
        // ---- handshakes of the cycle that just ended ----
        if(vme_if.uop_vme2lsu_vld === 1'b1 && vme_if.uop_vme2lsu_rdy === 1'b1) store_beat();
        ld_taken = (vme_if.uop_lsu2vme_vld === 1'b1 && vme_if.uop_lsu2vme_rdy === 1'b1);
        if(ld_taken) load_beat_done();

        // ---- drive the next cycle ----
        vme_if.uop_vme2lsu_rdy <= ($urandom_range(1, 100) <= st_rdy_pct);
        // valid / data are held until the DUT takes them; a new beat starts after a random delay
        if(vme_if.uop_lsu2vme_vld === 1'b1 && !ld_taken) begin
          // hold
        end else if(ls_q.size() > 0 && ls_q[0].alu_inst == VTLE && $urandom_range(1, 100) <= ld_vld_pct) begin
          drive_load_beat();
        end else begin
          vme_if.uop_lsu2vme_vld <= 1'b0;
        end
      end
    end
  endtask

  // vtse: the DUT hands over uop `uop_cnt` of the oldest instruction
  function void store_beat();
    rvs_transaction t;
    logic [`VLEN-1:0] d;
    if(ls_q.size() == 0 || ls_q[0].alu_inst != VTSE) begin
      `uvm_error("VME_DRV", $sformatf("vme2lsu store data (pc=0x%08x uop %0d) while the oldest outstanding tile load/store is %s",
                                     vme_if.uop_vme2lsu.uop_pc, vme_if.uop_vme2lsu.uop_index,
                                     ls_q.size() ? ls_q[0].asm_string : "none"))
      return;
    end
    t = ls_q[0];
    d = vme_if.uop_vme2lsu.r_data;
`ifdef TB_SUPPORT
    if(vme_if.uop_vme2lsu.uop_pc !== t.pc[`PC_WIDTH-1:0] || vme_if.uop_vme2lsu.uop_index !== uop_cnt[2:0])
      `uvm_error("VME_DRV", $sformatf("vme2lsu carries pc=0x%08x uop %0d, expected pc=0x%08x uop %0d (%s)",
                                     vme_if.uop_vme2lsu.uop_pc, vme_if.uop_vme2lsu.uop_index, t.pc, uop_cnt, t.asm_string))
`endif
    mem.pc = t.pc;
    for(int b = 0; b < `VLENB(`VLEN); b++) begin
      if(is_body(t, uop_cnt, b)) mem.store_byte(d[b*8 +: 8], t.zt_base + uop_cnt * `VLENB(`VLEN) + b);
    end
    `uvm_info("VME_DRV", $sformatf("vtse pc=0x%08x uop %0d data %h", t.pc, uop_cnt, d), UVM_HIGH)
    next_uop();
  endfunction

  // vtle: drive uop `uop_cnt` of the oldest instruction (re-driven unchanged until accepted)
  function void drive_load_beat();
    rvs_transaction t;
    `UOP_LSU2VME_t(`VLEN, `PC_WIDTH) u;
    t = ls_q[0];
    u = '0;
`ifdef TB_SUPPORT
    u.uop_pc    = t.pc;
    u.uop_index = uop_cnt;
`endif
    mem.pc = t.pc;
    for(int b = 0; b < `VLENB(`VLEN); b++) begin
      logic [7:0] v;
      if(is_body(t, uop_cnt, b)) v = mem.get_mem(t.zt_base + uop_cnt * `VLENB(`VLEN) + b);
      else                       v = $urandom_range(0, 255);
      u.w_data[b*8 +: 8] = v;
    end
    vme_if.uop_lsu2vme     <= u;
    vme_if.uop_lsu2vme_vld <= 1'b1;
  endfunction

  // the DUT took uop `uop_cnt` of the oldest vtle: record the body reads in the access stream
  function void load_beat_done();
    rvs_transaction t;
    if(ls_q.size() == 0 || ls_q[0].alu_inst != VTLE) begin
      `uvm_error("VME_DRV", "lsu2vme handshake without an outstanding vtle")
      return;
    end
    t = ls_q[0];
    mem.pc = t.pc;
    for(int b = 0; b < `VLENB(`VLEN); b++) begin
      logic [7:0] v;
      if(is_body(t, uop_cnt, b)) mem.load_byte(v, t.zt_base + uop_cnt * `VLENB(`VLEN) + b);
    end
    next_uop();
  endfunction

  function void next_uop();
    uop_cnt++;
    if(uop_cnt >= nuops(ls_q[0])) begin
      if(ls_q[0].alu_inst == VTLE) n_vtle++; else n_vtse++;
      ls_q.pop_front();
      uop_cnt = 0;
    end
  endfunction

  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    `uvm_info("FINAL_CHECK", $sformatf("Zvt LSU: %0d vtle and %0d vtse transferred.", n_vtle, n_vtse), UVM_NONE)
    if(ls_q.size() > 0) begin
      `uvm_error("FINAL_CHECK", $sformatf("%0d tile loads/stores never completed their data transfer; oldest %s (pc=0x%08x, %0d of %0d uops).",
                                         ls_q.size(), ls_q[0].asm_string, ls_q[0].pc, uop_cnt, nuops(ls_q[0])))
    end
  endfunction
endclass: vme_driver
`endif // ZVT_ON

`endif // VME_DRIVER__SV
