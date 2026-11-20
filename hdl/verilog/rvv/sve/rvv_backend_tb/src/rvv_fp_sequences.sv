`ifndef RVV_FP_SEQUENCES__SV
`define RVV_FP_SEQUENCES__SV

//===========================================================
// Floating point (Zve32f) instruction sequences
//
// One sequence class drives every OPF instruction. A test describes the instruction through
// an fp_inst_t (funct6, optional vs1/vs2 sub-function, which operand forms exist) and chooses
// between iterating the configuration space (LMUL x frm x vm) or random instructions.
//===========================================================
typedef struct {
  alu_inst_e    inst;
  bit           has_func;   // vfunary0/vfunary1: src1_idx selects the operation
  logic [4:0]   func;
  bit           vv;         // .vv form exists
  bit           vf;         // .vf form exists
  sew_e         sew;        // SEW of the vtype that makes the instruction legal
  bit           widen_or_narrow; // dest/src is twice as wide: LMUL8 is illegal
  bit           vm_fixed1;  // vm must be 1 (vfmv.f.s / vfmv.s.f)
} fp_inst_t;

class fp_seq extends base_sequence;
  `uvm_object_utils(fp_seq)
  `uvm_add_to_seq_lib(fp_seq,rvs_sequencer_sequence_library)

  fp_inst_t         fp_inst;
  // plain copies of fp_inst for use in inline constraints
  alu_inst_e        c_inst;
  bit               c_has_func, c_vv, c_vf, c_vm1;
  logic [4:0]       c_func;
  sew_e             c_sew;
  bit               vm;
  test_rand_type_e  rand_type = ITER;
  int               inst_num = 1;

  function new(string name = "fp_seq");
    super.new(name);
    `ifdef UVM_POST_VERSION_1_1
      set_automatic_phase_objection(1);
    `endif
  endfunction: new

  task run_iter(fp_inst_t inst, uvm_sequencer_base sqr, bit vm = 0);
    this.fp_inst   = inst;
    this.vm        = inst.vm_fixed1 ? 1'b1 : vm;
    this.rand_type = ITER;
    this.start(sqr);
  endtask: run_iter

  task run_rand(fp_inst_t inst, uvm_sequencer_base sqr, int inst_num = 50);
    this.fp_inst   = inst;
    this.rand_type = RAND;
    this.inst_num  = inst_num;
    this.start(sqr);
  endtask: run_rand

  // Operand forms the instruction supports
  function bit allow_vv(); return fp_inst.vv; endfunction
  function bit allow_vf(); return fp_inst.vf; endfunction

  virtual task body();
    c_inst = fp_inst.inst; c_has_func = fp_inst.has_func; c_func = fp_inst.func;
    c_vv = fp_inst.vv; c_vf = fp_inst.vf; c_sew = fp_inst.sew; c_vm1 = fp_inst.vm_fixed1;
    if(rand_type == RAND) begin
      repeat(inst_num) begin
        req = new("req");
        start_item(req);
        assert(req.randomize() with {
          vlmul dist {
            LMUL1_4 := 10,
            LMUL1_2 := 20,
            LMUL1   := 20,
            LMUL2   := 30,
            LMUL4   :=  5,
            LMUL8   := 15
          };
          vsew == local::c_sew;
          inst_type == ALU;
          alu_inst == local::c_inst;
          if(local::c_has_func) { src1_idx == local::c_func; }
          if(local::c_vv && !local::c_vf) { alu_type == OPFVV; }
          if(!local::c_vv && local::c_vf) { alu_type == OPFVF; }
          if(local::c_vm1) { vm == 1; }
        });
        req.pc = inst_cnt;
        finish_item(req);
        inst_cnt++;
      end
    end else begin
      // every LMUL and every legal rounding mode, VLMAX elements
      for(lmul_e lm = lm.first(); lm != lm.last(); lm = lm.next()) begin
        if(fp_inst.widen_or_narrow && lm == LMUL8) continue;
        for(int rm = 0; rm < 5; rm++) begin
          for(int form = 0; form < 2; form++) begin
            if(form == 0 && !fp_inst.vv) continue;
            if(form == 1 && !fp_inst.vf) continue;
            req = new("req");
            start_item(req);
            assert(req.randomize() with {
              use_vlmax == 1;
              vsew  == local::c_sew;
              vlmul == lm;
              frm   == rm;
              vm    == local::vm;
              inst_type == ALU;
              alu_inst  == local::c_inst;
              alu_type  == ((form == 0) ? OPFVV : OPFVF);
              if(local::c_has_func) { src1_idx == local::c_func; }
            });
            req.pc = inst_cnt;
            finish_item(req);
            inst_cnt++;
          end
        end
      end
    end
  endtask
endclass: fp_seq

//-----------------------------------------------------------
// Random mix of floating point instructions, with random vl/vstart/vm/LMUL/frm
//-----------------------------------------------------------
class fp_random_seq extends base_sequence;
  `uvm_object_utils(fp_random_seq)
  `uvm_add_to_seq_lib(fp_random_seq,rvs_sequencer_sequence_library)

  fp_inst_t fp_set [$];
  alu_inst_e   c_inst;
  bit          c_has_func, c_vv, c_vf, c_vm1;
  logic [4:0]  c_func;
  sew_e        c_sew;
  int       inst_num = 100;

  function new(string name = "fp_random_seq");
    super.new(name);
    `ifdef UVM_POST_VERSION_1_1
      set_automatic_phase_objection(1);
    `endif
  endfunction: new

  task run_set(fp_inst_t set[$], uvm_sequencer_base sqr, int inst_num = 100);
    this.fp_set   = set;
    this.inst_num = inst_num;
    this.start(sqr);
  endtask: run_set

  virtual task body();
    fp_inst_t fi;
    repeat(inst_num) begin
      fi = fp_set[$urandom_range(0, fp_set.size()-1)];
      c_inst = fi.inst; c_has_func = fi.has_func; c_func = fi.func;
      c_vv = fi.vv; c_vf = fi.vf; c_sew = fi.sew; c_vm1 = fi.vm_fixed1;
      req = new("req");
      start_item(req);
      assert(req.randomize() with {
        vlmul dist {
          LMUL1_4 := 10,
          LMUL1_2 := 20,
          LMUL1   := 20,
          LMUL2   := 30,
          LMUL4   :=  5,
          LMUL8   := 15
        };
        vsew == local::c_sew;
        inst_type == ALU;
        alu_inst  == local::c_inst;
        if(local::c_has_func) { src1_idx == local::c_func; }
        if(local::c_vv && !local::c_vf) { alu_type == OPFVV; }
        if(!local::c_vv && local::c_vf) { alu_type == OPFVF; }
        if(local::c_vm1) { vm == 1; }
      });
      req.pc = inst_cnt;
      finish_item(req);
      inst_cnt++;
    end
  endtask
endclass: fp_random_seq

`endif // RVV_FP_SEQUENCES__SV
