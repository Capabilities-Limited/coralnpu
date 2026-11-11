`ifndef RVV_BACKEND_FP_TEST__SV
`define RVV_BACKEND_FP_TEST__SV

//-----------------------------------------------------------
// Floating point (Zve32f) tests. Build with `make FP=1`.
//
// Each test lists the instructions it covers. For every one it iterates LMUL x frm x vm with vl=VLMAX,
// then runs random instructions (random vl / vstart / mask / LMUL / frm), then finishes with a random
// mix of the whole list. The vector registers are filled with floating point values biased towards
// the interesting ones (0, inf, NaN, subnormals, integers, halves, extremes).
//-----------------------------------------------------------
class fp_test_base extends rvv_backend_test;
  `uvm_component_utils(fp_test_base)

  fp_inst_t     insts[$];
  fp_seq        fp_iter_seq;
  fp_random_seq fp_rand_seq;
  rvs_last_sequence rvs_last_seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Describe one instruction. vv / vf choose the operand forms that exist.
  function fp_inst_t fp(alu_inst_e inst, bit vv = 1, bit vf = 1, bit has_func = 0, logic [4:0] func = 0,
                        sew_e sew = SEW32, bit wn = 0, bit vm1 = 0);
    fp_inst_t r;
    r.inst = inst; r.vv = vv; r.vf = vf; r.has_func = has_func; r.func = func;
    r.sew = sew; r.widen_or_narrow = wn; r.vm_fixed1 = vm1;
    return r;
  endfunction

  // Override: fill `insts`
  virtual function void configure_fp();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    rvs_transaction::fp_en = 1;
    configure_fp();
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    this.set_report_id_action_hier("MDL", UVM_LOG);
  endfunction

  virtual task main_phase(uvm_phase phase);
    rand_vrf_fp();

    fp_iter_seq = fp_seq::type_id::create("fp_iter_seq", this);
    foreach(insts[i]) begin
      fp_iter_seq.run_iter(insts[i], env.rvs_agt.rvs_sqr, 0);
      if(!insts[i].vm_fixed1) fp_iter_seq.run_iter(insts[i], env.rvs_agt.rvs_sqr, 1);
    end
    foreach(insts[i]) begin
      fp_iter_seq.run_rand(insts[i], env.rvs_agt.rvs_sqr, direct_inst_num);
    end

    fp_rand_seq = fp_random_seq::type_id::create("fp_rand_seq", this);
    fp_rand_seq.run_set(insts, env.rvs_agt.rvs_sqr, direct_inst_num * insts.size());

    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: fp_test_base

// vfadd / vfsub / vfrsub / vfmul
class fp_addmul_test extends fp_test_base;
  `uvm_component_utils(fp_addmul_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFADD));
    insts.push_back(fp(VFSUB));
    insts.push_back(fp(VFRSUB, 0, 1));
    insts.push_back(fp(VFMUL));
  endfunction
endclass: fp_addmul_test

// vfdiv / vfrdiv / vfsqrt
class fp_div_test extends fp_test_base;
  `uvm_component_utils(fp_div_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFDIV));
    insts.push_back(fp(VFRDIV, 0, 1));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFSQRT));
  endfunction
endclass: fp_div_test

// fused multiply-add family
class fp_fma_test extends fp_test_base;
  `uvm_component_utils(fp_fma_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFMACC));  insts.push_back(fp(VFNMACC));
    insts.push_back(fp(VFMSAC));  insts.push_back(fp(VFNMSAC));
    insts.push_back(fp(VFMADD));  insts.push_back(fp(VFNMADD));
    insts.push_back(fp(VFMSUB));  insts.push_back(fp(VFNMSUB));
  endfunction
endclass: fp_fma_test

// vfmin / vfmax / sign injection
class fp_minmax_sgnj_test extends fp_test_base;
  `uvm_component_utils(fp_minmax_sgnj_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFMIN));   insts.push_back(fp(VFMAX));
    insts.push_back(fp(VFSGNJ));  insts.push_back(fp(VFSGNJN));  insts.push_back(fp(VFSGNJX));
  endfunction
endclass: fp_minmax_sgnj_test

// mask-producing compares
class fp_cmp_test extends fp_test_base;
  `uvm_component_utils(fp_cmp_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VMFEQ));  insts.push_back(fp(VMFNE));
    insts.push_back(fp(VMFLT));  insts.push_back(fp(VMFLE));
    insts.push_back(fp(VMFGT, 0, 1));  insts.push_back(fp(VMFGE, 0, 1));
  endfunction
endclass: fp_cmp_test

// vfrec7 / vfrsqrt7 / vfclass
class fp_unary_test extends fp_test_base;
  `uvm_component_utils(fp_unary_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFSQRT));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFRSQRT7));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFREC7));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFCLASS));
  endfunction
endclass: fp_unary_test

// float <-> integer conversions, including the int16 <-> fp32 widening / narrowing forms
class fp_cvt_test extends fp_test_base;
  `uvm_component_utils(fp_cvt_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_XU_F));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_X_F));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_F_XU));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_F_X));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_RTZ_XU_F));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_RTZ_X_F));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFWCVT_F_XU,     SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFWCVT_F_X,      SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFNCVT_XU_F,     SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFNCVT_X_F,      SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFNCVT_RTZ_XU_F, SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFNCVT_RTZ_X_F,  SEW16, 1));
  endfunction
endclass: fp_cvt_test

// reductions
class fp_red_test extends fp_test_base;
  `uvm_component_utils(fp_red_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFREDOSUM, 1, 0));  insts.push_back(fp(VFREDUSUM, 1, 0));
    insts.push_back(fp(VFREDMIN,  1, 0));  insts.push_back(fp(VFREDMAX,  1, 0));
  endfunction
endclass: fp_red_test

// moves, merge and slide1
class fp_move_test extends fp_test_base;
  `uvm_component_utils(fp_move_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFMERGE_VFMV, 0, 1));                    // vfmerge.vfm / vfmv.v.f
    insts.push_back(fp(VWFUNARY0, 1, 0, 1, VFMV_F_S, SEW32, 0, 1));  // vfmv.f.s
    insts.push_back(fp(VWFUNARY0, 0, 1, 1, VFMV_S_F, SEW32, 0, 1));  // vfmv.s.f
    insts.push_back(fp(VFSLIDE1UP, 0, 1));
    insts.push_back(fp(VFSLIDE1DOWN, 0, 1));
  endfunction
endclass: fp_move_test

// Everything, interleaved: the operand data, rounding modes and configurations all change
// from instruction to instruction. Also mixes integer instructions between the FP ones.
class fp_random_mix_test extends fp_test_base;
  `uvm_component_utils(fp_random_mix_test)
  alu_random_seq int_rand_seq;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFADD));  insts.push_back(fp(VFSUB));  insts.push_back(fp(VFMUL)); insts.push_back(fp(VFDIV));
    insts.push_back(fp(VFRSUB, 0, 1));  insts.push_back(fp(VFRDIV, 0, 1));
    insts.push_back(fp(VFMACC)); insts.push_back(fp(VFNMSUB)); insts.push_back(fp(VFMSAC)); insts.push_back(fp(VFNMADD));
    insts.push_back(fp(VFMIN));  insts.push_back(fp(VFMAX));  insts.push_back(fp(VFSGNJX));
    insts.push_back(fp(VMFLT));  insts.push_back(fp(VMFEQ));  insts.push_back(fp(VMFGE, 0, 1));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFCLASS));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFSQRT));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFREC7));
    insts.push_back(fp(VFUNARY1, 1, 0, 1, VFRSQRT7));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_X_F));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_F_XU));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFNCVT_X_F, SEW16, 1));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFWCVT_F_X, SEW16, 1));
    insts.push_back(fp(VFREDUSUM, 1, 0));  insts.push_back(fp(VFREDMAX, 1, 0));
    insts.push_back(fp(VFMERGE_VFMV, 0, 1));
    insts.push_back(fp(VWFUNARY0, 1, 0, 1, VFMV_F_S, SEW32, 0, 1));
    insts.push_back(fp(VWFUNARY0, 0, 1, 1, VFMV_S_F, SEW32, 0, 1));
    insts.push_back(fp(VFSLIDE1UP, 0, 1));
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf_fp();
    fp_rand_seq = fp_random_seq::type_id::create("fp_rand_seq", this);
    int_rand_seq = alu_random_seq::type_id::create("int_rand_seq", this);
    repeat(10) begin
      fp_rand_seq.run_set(insts, env.rvs_agt.rvs_sqr, random_inst_num / 50);
      // integer instructions in between: the FP state must not disturb them and vice versa
      int_rand_seq.run_rand_with_set('{VADD, VSUB, VMUL, VMERGE_VMVV, VMSLT, VAND}, env.rvs_agt.rvs_sqr, random_inst_num / 200);
    end
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: fp_random_mix_test

// Encodings the DUT must reject: reserved frm (5, 6, 7 and the unimplemented dynamic mode) and
// SEW != 32. The monitor/model treat these as discarded instructions, so any retire of one is an error.
class fp_illegal_test extends fp_test_base;
  `uvm_component_utils(fp_illegal_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure_fp();
    insts.push_back(fp(VFADD));  insts.push_back(fp(VFMUL));  insts.push_back(fp(VFMACC));
    insts.push_back(fp(VMFLT));  insts.push_back(fp(VFUNARY1, 1, 0, 1, VFCLASS));
    insts.push_back(fp(VFUNARY0, 1, 0, 1, VFCVT_X_F));
  endfunction
  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    rvs_transaction::reserve_frm_en  = 1;
    rvs_transaction::reserve_vtype_en = 1;
  endfunction
  virtual task main_phase(uvm_phase phase);
    rand_vrf_fp();
    fp_rand_seq = fp_random_seq::type_id::create("fp_rand_seq", this);
    // legal-looking instructions with the encodings the DUT rejects mixed in
    fp_rand_seq.run_set(insts, env.rvs_agt.rvs_sqr, random_inst_num / 10);
    rvs_last_seq = rvs_last_sequence::type_id::create("rvs_last_seq", this);
    rvs_last_seq.start(env.rvs_agt.rvs_sqr);
  endtask
endclass: fp_illegal_test

`endif // RVV_BACKEND_FP_TEST__SV
