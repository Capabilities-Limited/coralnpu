`ifndef RVV_BACKEND_ZVT_TEST__SV
`define RVV_BACKEND_ZVT_TEST__SV

//-----------------------------------------------------------
// Zvt (matrix extension) tests. Build with `make ZVT=1`.
//-----------------------------------------------------------
class zvt_basic_test extends rvv_backend_test;
  `uvm_component_utils(zvt_basic_test)

  zvt_seq           seq;
  rvs_last_sequence rvs_last_seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    rvs_transaction::zvt_en = 1;
    void'($value$plusargs("zvt_inst_num=%d", direct_inst_num));   // length of the random / ldst sequences
  endfunction

  // the memory the tile loads / stores use (zvt_seq::MEM_LO .. MEM_HI)
  virtual task configure_phase(uvm_phase phase);
    super.configure_phase(phase);
    rand_mem(zvt_seq::MEM_LO, zvt_seq::MEM_HI);
  endtask

  virtual task main_phase(uvm_phase phase);
    rand_vrf();
    seq = zvt_seq::type_id::create("seq", this);
    seq.inst_num = direct_inst_num;
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_basic_test

class zvt_fp_test extends zvt_basic_test;
  `uvm_component_utils(zvt_fp_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf_fp();
    seq = zvt_seq::type_id::create("seq", this);
    seq.inst_num = direct_inst_num;
    seq.use_fp   = 1;
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_fp_test

// Directed sweeps of tm / tn for the matmuls, on a fresh tile each time (see zvt_seq::sweep).
class zvt_fp_sweep_test extends zvt_basic_test;
  `uvm_component_utils(zvt_fp_sweep_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf_fp();
    seq = zvt_seq::type_id::create("seq", this);
    seq.mode = 1;
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_fp_sweep_test

class zvt_int_sweep_test extends zvt_basic_test;
  `uvm_component_utils(zvt_int_sweep_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf();
    seq = zvt_seq::type_id::create("seq", this);
    seq.mode = 2;
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_int_sweep_test

// Tile loads / stores (vtle / vtse) for every EEW and pattern (see zvt_seq::ldst_sweep).
class zvt_ldst_test extends zvt_basic_test;
  `uvm_component_utils(zvt_ldst_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf();
    seq = zvt_seq::type_id::create("seq", this);
    seq.inst_num = direct_inst_num;
    seq.mode     = 4;
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_ldst_test

// One FP32 matmul on clean, structured data: word w of vector register r holds the float 4*r+w+1, so
// A[m] = 4*vs2+m+1 and B[n] = 4*vs1+n+1 and every product is an exact small integer. Meant for decoding
// what the DUT computes; the dimensions and registers come from plusargs (see zvt_seq::single).
class zvt_fp_pattern_test extends zvt_basic_test;
  `uvm_component_utils(zvt_fp_pattern_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task main_phase(uvm_phase phase);
    logic [`VLEN-1:0] vals [32];
    int vs2 = 8, vs1 = 12, pidx;
    logic [31:0] pval;
    void'($value$plusargs("zvt_vs2=%d", vs2));
    void'($value$plusargs("zvt_vs1=%d", vs1));
    for(int r = 0; r < 32; r++)
      for(int w = 0; w < `VLEN/32; w++) vals[r][w*32 +: 32] = rvv_softfloat_pkg::f_from_int(32'(4*r + w + 1), rvv_softfloat_pkg::RM_RNE, 1'b1, 32).val;
    // optionally replace one operand element: A[m] / B[n] <- value (plusargs zvt_poke_a_idx/_val, zvt_poke_b_idx/_val)
    if($value$plusargs("zvt_poke_a_idx=%d", pidx)) begin
      pval = 32'h0040_0000; void'($value$plusargs("zvt_poke_a_val=%h", pval));
      vals[vs2 + pidx/4][(pidx%4)*32 +: 32] = pval;
    end
    if($value$plusargs("zvt_poke_b_idx=%d", pidx)) begin
      pval = 32'h0040_0000; void'($value$plusargs("zvt_poke_b_val=%h", pval));
      vals[vs1 + pidx/4][(pidx%4)*32 +: 32] = pval;
    end
    // whole operand lists: +zvt_a_list=h0_h1_... sets A[0..], +zvt_b_list=... sets B[0..] (hex words, '_' separated)
    begin
      string lst;
      int idx;
      if($value$plusargs("zvt_a_list=%s", lst)) begin
        idx = 0;
        while(lst.len() > 0) begin
          int us; logic [31:0] hv;
          us = -1;
          for(int ci = 0; ci < lst.len(); ci++) if(lst[ci] == "_") begin us = ci; break; end
          void'($sscanf((us < 0) ? lst : lst.substr(0, us-1), "%h", hv));
          vals[vs2 + idx/4][(idx%4)*32 +: 32] = hv;
          idx++;
          lst = (us < 0) ? "" : lst.substr(us+1, lst.len()-1);
        end
      end
      if($value$plusargs("zvt_b_list=%s", lst)) begin
        idx = 0;
        while(lst.len() > 0) begin
          int us; logic [31:0] hv;
          us = -1;
          for(int ci = 0; ci < lst.len(); ci++) if(lst[ci] == "_") begin us = ci; break; end
          void'($sscanf((us < 0) ? lst : lst.substr(0, us-1), "%h", hv));
          vals[vs1 + idx/4][(idx%4)*32 +: 32] = hv;
          idx++;
          lst = (us < 0) ? "" : lst.substr(us+1, lst.len()-1);
        end
      end
    end
    for(int r = 0; r < 32; r++) set_vrf(r, vals[r]);
    seq = zvt_seq::type_id::create("seq", this);
    seq.mode = 3;
    void'($value$plusargs("zvt_mode=%d", seq.mode));   // debug: run another sequence on this data
    seq.start(env.rvs_agt.rvs_sqr);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: zvt_fp_pattern_test

`endif // RVV_BACKEND_ZVT_TEST__SV
