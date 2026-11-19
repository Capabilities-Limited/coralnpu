`ifndef RVS_TRANSACTION_ZVT__SV
`define RVS_TRANSACTION_ZVT__SV

// Zvt (matrix extension) side of rvs_transaction. Legality and semantics follow the Zvt 0.4 spec
// (see include/rvv_zvt_model.svh); the encodings are the ones the backend decodes: the matrix
// multiplies as funct6=111100 under OP-V (the Chisel scalar decoder maps the spec's OP-VE form onto
// the same command), the rest as the spec encodes them.

// Number of elements a tile move / load / store touches: [vstart, min(vl, ETE) - 1]
function automatic int unsigned zvt_tn(int unsigned vl, int unsigned tew);
  return rvv_zvt_pkg::zvt_body_end(vl, tew);
endfunction

// -------------------------------------------------------------------------------------------------
// zvt_build: set up a complete Zvt instruction, the way msetmtype / msettn / msettm / msettk would have
// configured the machine before it. Nothing here is randomised by the solver.
//   vtzero:      tile = mtd
//   vtmmu/vtmms/vtfmm: tile = mtd, vd_or_vs2 = vs2 (A), vs1_or_none = vs1 (B)
//   vtmv.v.t:    vd_or_vs2 = vd; the tile subset is (tile, pattern, index)
//   vtmv.t.v:    vd_or_vs2 = vs2; the tile subset is (tile, pattern, index)
//   vtle/vtse:   the tile subset is (tile, pattern, index), base the memory address, ew the EEW
// -------------------------------------------------------------------------------------------------
function void rvs_transaction::zvt_build(alu_inst_e inst, int sew_bits, int mtwiden_v, int tm_v, int vl_v, int tk_v,
                                         bit altfmt_v, int tile, int vd_or_vs2, int vs1_or_none, int pattern, int index,
                                         int vstart_v = 0, int base_reg_rs1 = 5, logic [31:0] base = 32'h0, int ew = 32);
  rvv_zvt_pkg::zvt_cfg_t cfg;
  int unsigned lm;
  cfg = rvv_zvt_pkg::zvt_msetmtype(sew_bits, mtwiden_v, tm_v, tk_v, altfmt_v);
  if(cfg.vill || cfg.mtwiden == 0) `uvm_fatal("ZVT_BUILD", $sformatf("sew=%0d mtwiden=%0d is not a valid matrix configuration", sew_bits, mtwiden_v))

  inst_type   = ALU;
  alu_inst    = inst;
  is_zvt_inst = 1;
  is_zvt_vme  = (inst != VTMV_V_T);
  case(inst)
    VTMMU, VTMMS: alu_type = OPIVV;
    VTFMM:        alu_type = OPFVV;
    default:      alu_type = OPMVX;
  endcase

  // vtype / mtype state
  vill   = 0;
  assert($cast(vsew, (sew_bits == 8) ? 0 : (sew_bits == 16) ? 1 : 2));
  case(cfg.lmul)
    1: vlmul = LMUL1;
    2: vlmul = LMUL2;
    4: vlmul = LMUL4;
    default: vlmul = LMUL8;
  endcase
  vma     = AGNOSTIC;   // forced by msetmtype
  vta     = AGNOSTIC;
  vxrm    = RNU;
  frm     = (inst == VTFMM) ? $urandom_range(0, 4) : 0;
  if(inst == VTFMM) begin int f; if($value$plusargs("zvt_frm=%d", f)) frm = f; end   // debug: pin the rounding mode
  mtwiden = cfg.mtwiden;
  tm      = cfg.tm;
  tk      = cfg.tk;
  altfmt  = altfmt_v;
  vl      = rvv_zvt_pkg::zvt_msettn(cfg, vl_v);
  vstart  = vstart_v;
  vm      = 1;
  use_vlmax = 0;
  evl     = vl;

  zt_tile    = tile;
  zt_pattern = pattern;
  zt_index   = index;
  zt_base    = base;
  zt_ew      = ew;

  // operands
  dest_type = UNUSE; src1_type = UNUSE; src2_type = UNUSE; src3_type = UNUSE;
  dest_idx = 0; src1_idx = 0; src2_idx = 0; src3_idx = 0;
  rs1_data = 'x; rs2_data = 'x;
  case(inst)
    VTMMU, VTMMS, VTFMM: begin
      // rd[0]: vtmms (vs2 signed) / vtfmm.alt (vs2 E5M2/BF16). It is an opcode bit, not vtype.altfmt (which
      // selects the vs1 datatype); the FP32 matmul only exists as vtfmm.tvv.
      dest_idx  = (tile << 1) | ((inst == VTMMS) ? 1 : 0);
      src2_idx  = vd_or_vs2;
      src1_idx  = vs1_or_none;
    end
    VTZERO: begin
      dest_idx  = tile << 1;
    end
    VTMV_V_T: begin
      dest_type = VRF;
      dest_idx  = vd_or_vs2;
      src1_type = XRF;
      src1_idx  = base_reg_rs1;
      rs1_data  = rvv_zvt_pkg::zvt_tss_encode(tile, pattern, index);
    end
    VTMV_T_V: begin
      src2_type = VRF;
      src2_idx  = vd_or_vs2;
      src1_type = XRF;
      src1_idx  = base_reg_rs1;
      rs1_data  = rvv_zvt_pkg::zvt_tss_encode(tile, pattern, index);
    end
    VTLE, VTSE: begin
      src1_type = XRF;
      src1_idx  = base_reg_rs1;                 // rs1: base address register
      src2_idx  = base_reg_rs1 + 1;             // rs2: tile subset specifier register
      rs1_data  = rvv_zvt_pkg::zvt_tss_encode(tile, pattern, index);  // what the backend gets in cmd.rs1
    end
  endcase

  decode_vtype(1, 1);
  evl = vl;
  get_vec_group_range();
  zvt_tr2bin();
  zvt_asm();
endfunction: zvt_build

// -------------------------------------------------------------------------------------------------
// Encoding
// -------------------------------------------------------------------------------------------------
function void rvs_transaction::zvt_tr2bin();
  logic [4:0] tile5;
  bin_inst = '0;
  bin_inst[25] = 1'b1;   // vm
  case(alu_inst)
    VTMMU, VTMMS, VTFMM: begin
      bin_inst[6:0]   = 7'b1010111;
      bin_inst[31:26] = 6'b111100;
      bin_inst[24:20] = src2_idx[4:0];
      bin_inst[19:15] = src1_idx[4:0];
      bin_inst[14:12] = (alu_inst == VTFMM) ? 3'b001 : 3'b000;
      bin_inst[11:7]  = dest_idx[4:0];
    end
    VTMV_V_T: begin
      bin_inst[6:0]   = 7'b1010111;
      bin_inst[31:26] = 6'b010000;
      bin_inst[24:20] = 5'b11111;
      bin_inst[19:15] = src1_idx[4:0];
      bin_inst[14:12] = 3'b110;
      bin_inst[11:7]  = dest_idx[4:0];
    end
    VTMV_T_V: begin
      bin_inst[6:0]   = 7'b1010111;
      bin_inst[31:26] = 6'b010111;
      bin_inst[24:20] = src2_idx[4:0];
      bin_inst[19:15] = src1_idx[4:0];
      bin_inst[14:12] = 3'b110;
      bin_inst[11:7]  = 5'b0;
    end
    VTZERO: begin
      bin_inst[6:0]   = 7'b1010111;
      bin_inst[31:26] = 6'b010000;
      bin_inst[24:20] = 5'b11110;
      bin_inst[19:15] = 5'b0;
      bin_inst[14:12] = 3'b110;
      bin_inst[11:7]  = dest_idx[4:0];
    end
    VTLE, VTSE: begin
      bin_inst[6:0]   = (alu_inst == VTLE) ? 7'b0000111 : 7'b0100111;
      case(zt_ew)
        8:  bin_inst[31:29] = 3'b000;
        16: bin_inst[31:29] = 3'b001;
        32: bin_inst[31:29] = 3'b010;
        default: bin_inst[31:29] = 3'b011;
      endcase
      bin_inst[28]    = 1'b1;       // mew
      bin_inst[27:26] = 2'b00;      // mop
      bin_inst[24:20] = src2_idx[4:0];
      bin_inst[19:15] = src1_idx[4:0];
      bin_inst[14:12] = 3'b111;
      bin_inst[11:7]  = 5'b0;
    end
  endcase
endfunction: zvt_tr2bin

// -------------------------------------------------------------------------------------------------
// Decode (monitor side). Returns 1 when `inst_in` is a Zvt instruction. The configuration the
// instruction ran under (vcsr fields, mtwiden, tm, tk, altfmt) was set by the caller beforehand.
// -------------------------------------------------------------------------------------------------
function bit rvs_transaction::zvt_bin2tr(logic [31:0] inst_in, logic [`XLEN-1:0] rs_data);
  logic [6:0] opc;
  logic [5:0] f6;
  logic [2:0] f3;
  logic [4:0] vs2f;
  bit         found;
  opc  = inst_in[6:0];
  f6   = inst_in[31:26];
  f3   = inst_in[14:12];
  vs2f = inst_in[24:20];
  found = 0;
  is_zvt_inst = 0;

  if(opc == 7'b1010111 && inst_in[25]) begin
    if(f6 == 6'b111100 && f3 == 3'b000) begin
      alu_inst = inst_in[7] ? VTMMS : VTMMU;  found = 1;  alu_type = OPIVV;
    end else if(f6 == 6'b111100 && f3 == 3'b001) begin
      alu_inst = VTFMM;  found = 1;  alu_type = OPFVV;
    end else if(f3 == 3'b110 && f6 == 6'b010000 && vs2f == 5'b11111) begin
      alu_inst = VTMV_V_T;  found = 1;  alu_type = OPMVX;
    end else if(f3 == 3'b110 && f6 == 6'b010000 && vs2f == 5'b11110 && inst_in[19:15] == 5'b0) begin
      alu_inst = VTZERO;  found = 1;  alu_type = OPMVX;
    end else if(f3 == 3'b110 && f6 == 6'b010111) begin
      alu_inst = VTMV_T_V;  found = 1;  alu_type = OPMVX;
    end
  end else if((opc == 7'b0000111 || opc == 7'b0100111) && inst_in[28:26] == 3'b100 && inst_in[25] && inst_in[14:12] == 3'b111) begin
    alu_inst = (opc == 7'b0000111) ? VTLE : VTSE;  found = 1;  alu_type = OPMVX;
    case(inst_in[31:29])
      3'b000: zt_ew = 8;
      3'b001: zt_ew = 16;
      3'b010: zt_ew = 32;
      3'b011: zt_ew = 64;
      default: zt_ew = 0;   // 1xx: reserved
    endcase
  end
  if(!found) return 0;

  is_zvt_inst = 1;
  is_zvt_vme  = (alu_inst != VTMV_V_T);
  inst_type   = ALU;
  vm          = 1;
  dest_type = UNUSE; src1_type = UNUSE; src2_type = UNUSE; src3_type = UNUSE;
  dest_idx = 0; src1_idx = inst_in[19:15]; src2_idx = inst_in[24:20]; src3_idx = 0;
  rs1_data = 'x; rs2_data = 'x;
  case(alu_inst)
    VTMMU, VTMMS, VTFMM: begin
      dest_idx = inst_in[11:7];
      zt_tile  = inst_in[11:8];
    end
    VTZERO: begin
      dest_idx = inst_in[11:7];
      zt_tile  = inst_in[11:8];
    end
    VTMV_V_T: begin
      dest_type = VRF;  dest_idx = inst_in[11:7];
      src1_type = XRF;  rs1_data = rs_data;
    end
    VTMV_T_V: begin
      src2_type = VRF;
      src1_type = XRF;  rs1_data = rs_data;
    end
    VTLE, VTSE: begin
      src1_type = XRF;  rs1_data = rs_data;     // cmd.rs1 carries the tile subset specifier
    end
  endcase
  if(alu_inst inside {VTMV_V_T, VTMV_T_V, VTLE, VTSE}) begin
    rvv_zvt_pkg::zvt_tss_t t;
    t = rvv_zvt_pkg::zvt_tss_decode(rs_data);
    zt_tile = t.tile;  zt_pattern = t.pattern;  zt_index = t.index;
  end
  evl = vl;
  decode_vtype(1, 1);
  evl = vl;
  get_vec_group_range();
  zvt_asm();
  return 1;
endfunction: zvt_bin2tr

// -------------------------------------------------------------------------------------------------
// Legality, per the spec. 1: the instruction is legal and executes, 0: reserved. The cases the model
// does not cover (FP8 / FP16 / BF16 / FP64 matmuls, TEW=64) are reported as not legal here, so the
// generators must not produce them.
// -------------------------------------------------------------------------------------------------
function bit rvs_transaction::zvt_check();
  int unsigned sew_bits, twiden, tew, ete, lm, kmax, vsmask;
  rvv_zvt_pkg::zvt_cfg_t cfg;
  rvv_zvt_pkg::zvt_tss_t tss;
  sew_bits = 8 << vsew;
  twiden   = rvv_zvt_pkg::zvt_twiden(mtwiden);

  // "If mtwiden=0, these instructions are reserved"
  if(mtwiden == 0) begin
    `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: Zvt instruction with mtwiden=0 is reserved.", pc))
    return 0;
  end
  cfg = rvv_zvt_pkg::zvt_msetmtype(sew_bits, mtwiden, tm, tk, altfmt);
  if(cfg.vill) begin
    `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: SEW=%0d TWIDEN=%0d is not a supported configuration.", pc, sew_bits, twiden))
    return 0;
  end
  // vtype.vlmul is set by msetmtype whenever mtwiden != 0
  case(vlmul) LMUL1: lm = 1; LMUL2: lm = 2; LMUL4: lm = 4; LMUL8: lm = 8; default: lm = 0; endcase
  if(lm != cfg.lmul) begin
    `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: LMUL=%0d does not match what msetmtype produces (%0d).", pc, lm, cfg.lmul))
    return 0;
  end
  tew = sew_bits * twiden;
  kmax = rvv_zvt_pkg::zvt_kmax(sew_bits, twiden);

  case(alu_inst)
    VTMMU, VTMMS, VTFMM: begin
      // Supported data types: int8 -> int32 (Zvti8i32mm), FP32 -> FP32 (Zvtfmm). The others are not modelled.
      if(alu_inst == VTFMM) begin
        // vtfmm.alt (rd[0]=1) has no SEW=32 form, so it is reserved there
        if(!(sew_bits == 32 && twiden == 1 && !altfmt && !dest_idx[0])) begin
          `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: %s SEW=%0d TWIDEN=%0d altfmt=%0d is reserved or not modelled.", pc, dest_idx[0] ? "vtfmm.alt" : "vtfmm", sew_bits, twiden, altfmt))
          return 0;
        end
      end else if(!(sew_bits == 8 && twiden == 4)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: %s SEW=%0d TWIDEN=%0d is not modelled.", pc, alu_inst.name(), sew_bits, twiden))
        return 0;
      end
      if(vstart != 0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: matmul with vstart=%0d raises illegal-instruction.", pc, vstart))
        return 0;
      end
      if(!rvv_zvt_pkg::zvt_tile_valid(dest_idx[4:1], tew)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: tile %0d is not a valid TEW=%0d tile.", pc, dest_idx[4:1], tew))
        return 0;
      end
      // Vector register specifiers: divisible by LMUL, and modulo 8 below 8/KMAX
      if((src2_idx % lm) != 0 || (src1_idx % lm) != 0 || ((src2_idx % 8) >= 8 / kmax) || ((src1_idx % 8) >= 8 / kmax)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: operand v%0d / v%0d violates the matrix register-group rules (LMUL=%0d KMAX=%0d).", pc, src2_idx, src1_idx, lm, kmax))
        return 0;
      end
    end
    VTZERO: begin
      if(vstart != 0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vtzero with vstart=%0d raises illegal-instruction.", pc, vstart))
        return 0;
      end
      if(bin_inst[7] != 1'b0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vtzero with rd[0]=1 is reserved.", pc))
        return 0;
      end
      if(!(tew inside {8, 16, 32})) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vtzero TEW=%0d is not modelled.", pc, tew))
        return 0;
      end
      if(!rvv_zvt_pkg::zvt_tile_valid(dest_idx[4:1], tew)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: tile %0d is not a valid TEW=%0d tile.", pc, dest_idx[4:1], tew))
        return 0;
      end
    end
    VTMV_V_T, VTMV_T_V: begin
      if(alu_inst == VTMV_T_V && bin_inst[11:7] != 5'b0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vtmv.t.v with rd!=0 is reserved.", pc))
        return 0;
      end
      tss = rvv_zvt_pkg::zvt_tss_decode(rs1_data);
      if(rvv_zvt_pkg::zvt_tss_reserved(tss, sew_bits)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: reserved tile subset specifier (pattern=%0d index=%0d).", pc, tss.pattern, tss.index))
        return 0;
      end
      if(alu_inst == VTMV_V_T && (dest_idx % lm) != 0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vd=v%0d is not a multiple of LMUL=%0d.", pc, dest_idx, lm))
        return 0;
      end
      if(alu_inst == VTMV_T_V && (src2_idx % lm) != 0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: vs2=v%0d is not a multiple of LMUL=%0d.", pc, src2_idx, lm))
        return 0;
      end
    end
    VTLE, VTSE: begin
      if(bin_inst[11:7] != 5'b0) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: tile load/store with vd!=0 is reserved.", pc))
        return 0;
      end
      // EEW > ELEN (and eee=1xx) is reserved; TEW=64 needs Zvt64e / Zve64x
      if(!(zt_ew inside {8, 16, 32})) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: tile load/store EEW=%0d is not modelled.", pc, zt_ew))
        return 0;
      end
      tss = rvv_zvt_pkg::zvt_tss_decode(rs1_data);
      if(rvv_zvt_pkg::zvt_tss_reserved(tss, zt_ew)) begin
        `uvm_warning("TR/INST_CHECK", $sformatf("pc=0x%8x: reserved tile subset specifier.", pc))
        return 0;
      end
    end
    default: return 0;
  endcase
  return 1;
endfunction: zvt_check

// -------------------------------------------------------------------------------------------------
function void rvs_transaction::zvt_asm();
  string name, ops;
  string cm;
  case(alu_inst)
    VTMMU:    begin name = "vtmmu.tvv";    ops = $sformatf("mt%0d, v%0d, v%0d", dest_idx[4:1], src2_idx, src1_idx); end
    VTMMS:    begin name = "vtmms.tvv";    ops = $sformatf("mt%0d, v%0d, v%0d", dest_idx[4:1], src2_idx, src1_idx); end
    VTFMM:    begin name = dest_idx[0] ? "vtfmm.alt.tvv" : "vtfmm.tvv"; ops = $sformatf("mt%0d, v%0d, v%0d", dest_idx[4:1], src2_idx, src1_idx); end
    VTZERO:   begin name = "vtzero";       ops = $sformatf("mt%0d", dest_idx[4:1]); end
    VTMV_V_T: begin name = "vtmv.v.t";     ops = $sformatf("v%0d, tss(mt%0d,%s,%0d)", dest_idx, zt_tile, zt_pattern ? "col" : "row", zt_index); end
    VTMV_T_V: begin name = "vtmv.t.v";     ops = $sformatf("tss(mt%0d,%s,%0d), v%0d", zt_tile, zt_pattern ? "col" : "row", zt_index, src2_idx); end
    VTLE:     begin name = $sformatf("vtle%0d", zt_ew); ops = $sformatf("tss(mt%0d,%s,%0d), (0x%08x)", zt_tile, zt_pattern ? "col" : "row", zt_index, zt_base); end
    VTSE:     begin name = $sformatf("vtse%0d", zt_ew); ops = $sformatf("tss(mt%0d,%s,%0d), (0x%08x)", zt_tile, zt_pattern ? "col" : "row", zt_index, zt_base); end
    default:  begin name = "zvt?"; ops = ""; end
  endcase
  cm = $sformatf("# sew=%0d mtwiden=%0d tm=%0d tk=%0d tn/vl=%0d vstart=%0d altfmt=%0d lmul=%s",
                 8 << vsew, mtwiden, tm, tk, vl, vstart, altfmt, vlmul.name());
  asm_string = $sformatf("%s %s %s", name, ops, cm);
endfunction: zvt_asm

`endif // RVS_TRANSACTION_ZVT__SV
