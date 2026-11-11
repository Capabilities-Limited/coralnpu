`ifndef RVV_FP_MODEL
`define RVV_FP_MODEL

//------------------------------------------------------------------------------
// CLASS: fp_processor
//
// Element-wise reference for the floating point (OPF*) instructions of Zve32f, built on the exact
// soft-float package. It plugs into the same per-element loop as the integer processors:
// operands arrive as raw bit patterns (zero-extended to 32 bits), the result is the raw bit
// pattern, and the exception flags of every element are reported through get_fflags().
//
// Operand roles follow the RVV spec:  vs2 = src2, vs1 / f[rs1] = src1, vd (old value) = dest,
// mask / merge select = src0.
//------------------------------------------------------------------------------
class fp_processor extends alu_base;
  `uvm_component_utils(fp_processor)

  logic [4:0] fflags;    // flags raised by the last exe() call
  logic [4:0] acc_flags; // OR over the instruction (reductions use it too)

  function new(string name = "fp_processor", uvm_component parent);
    super.new(name, parent);
  endfunction: new

  virtual function void reset();
    super.reset();
    fflags = '0;
  endfunction: reset

  function logic [4:0] get_fflags();
    return fflags;
  endfunction: get_fflags

  // An int16 or int32 source / destination is carried in the low bits of the 32-bit element.
  virtual function alu_unsigned_t exe_first_scalar (rvs_transaction inst_tr, alu_unsigned_t dest, alu_unsigned_t src2, alu_unsigned_t src1, alu_unsigned_t src0);
    // Reductions start from vs1[0]
    return src1;
  endfunction: exe_first_scalar

  virtual function alu_unsigned_t exe (rvs_transaction inst_tr, alu_unsigned_t dest, alu_unsigned_t src2, alu_unsigned_t src1, alu_unsigned_t src0);
    rvv_softfloat_pkg::fp_res_t r;
    rvv_softfloat_pkg::rm_e     rm;
    logic [31:0] a2, a1, ad;
    a2 = src2[31:0];
    a1 = src1[31:0];
    ad = dest[31:0];
    rm = rvv_softfloat_pkg::rm_e'(inst_tr.frm[2:0]);
    r  = '0;

    case(inst_tr.alu_inst)
      // Arithmetic ------------------------------------------------------------
      VFADD:   r = rvv_softfloat_pkg::f_add(a2, a1, rm);
      VFSUB:   r = rvv_softfloat_pkg::f_sub(a2, a1, rm);
      VFRSUB:  r = rvv_softfloat_pkg::f_sub(a1, a2, rm);
      VFMUL:   r = rvv_softfloat_pkg::f_mul(a2, a1, rm);
      VFDIV:   r = rvv_softfloat_pkg::f_div(a2, a1, rm);
      VFRDIV:  r = rvv_softfloat_pkg::f_div(a1, a2, rm);
      // vd = +-(vs1 * vs2) +- vd
      VFMACC:  r = rvv_softfloat_pkg::f_fma(a1, a2, ad, rm, 1'b0, 1'b0);
      VFNMACC: r = rvv_softfloat_pkg::f_fma(a1, a2, ad, rm, 1'b1, 1'b1);
      VFMSAC:  r = rvv_softfloat_pkg::f_fma(a1, a2, ad, rm, 1'b0, 1'b1);
      VFNMSAC: r = rvv_softfloat_pkg::f_fma(a1, a2, ad, rm, 1'b1, 1'b0);
      // vd = +-(vs1 * vd) +- vs2
      VFMADD:  r = rvv_softfloat_pkg::f_fma(a1, ad, a2, rm, 1'b0, 1'b0);
      VFNMADD: r = rvv_softfloat_pkg::f_fma(a1, ad, a2, rm, 1'b1, 1'b1);
      VFMSUB:  r = rvv_softfloat_pkg::f_fma(a1, ad, a2, rm, 1'b0, 1'b1);
      VFNMSUB: r = rvv_softfloat_pkg::f_fma(a1, ad, a2, rm, 1'b1, 1'b0);
      VFMIN:   r = rvv_softfloat_pkg::f_minmax(a2, a1, 1'b0);
      VFMAX:   r = rvv_softfloat_pkg::f_minmax(a2, a1, 1'b1);
      // Sign injection never raises flags and never touches NaN payloads
      VFSGNJ:  r.val = {a1[31],         a2[30:0]};
      VFSGNJN: r.val = {~a1[31],        a2[30:0]};
      VFSGNJX: r.val = {a1[31] ^ a2[31], a2[30:0]};
      // Compares: one result bit per element --------------------------------
      VMFEQ:   r = rvv_softfloat_pkg::f_eq(a2, a1);
      VMFNE: begin
        r = rvv_softfloat_pkg::f_eq(a2, a1);
        r.val = {31'b0, ~r.val[0]};     // unordered compares "not equal"
      end
      VMFLT:   r = rvv_softfloat_pkg::f_lt(a2, a1);
      VMFLE:   r = rvv_softfloat_pkg::f_le(a2, a1);
      VMFGT:   r = rvv_softfloat_pkg::f_lt(a1, a2);
      VMFGE:   r = rvv_softfloat_pkg::f_le(a1, a2);
      // Merge / move ------------------------------------------------------------
      VFMERGE_VFMV: r.val = src0[0] ? a1 : a2;
      // Single operand ------------------------------------------------------------
      VFUNARY1: begin
        case(inst_tr.src1_idx)
          VFSQRT:   r = rvv_softfloat_pkg::f_sqrt(a2, rm);
          VFRSQRT7: r = rvv_softfloat_pkg::f_rsqrt7(a2);
          VFREC7:   r = rvv_softfloat_pkg::f_rec7(a2, rm);
          VFCLASS:  r.val = {22'b0, rvv_softfloat_pkg::f_class(a2)};
          default:  `uvm_error("MDL/FP", $sformatf("vfunary1 vs1=%0d is not supported", inst_tr.src1_idx))
        endcase
      end
      VFUNARY0: begin
        case(inst_tr.src1_idx)
          VFCVT_XU_F:      r = rvv_softfloat_pkg::f_to_int(a2, rm, 1'b0, 32);
          VFCVT_X_F:       r = rvv_softfloat_pkg::f_to_int(a2, rm, 1'b1, 32);
          VFCVT_RTZ_XU_F:  r = rvv_softfloat_pkg::f_to_int(a2, rvv_softfloat_pkg::RM_RTZ, 1'b0, 32);
          VFCVT_RTZ_X_F:   r = rvv_softfloat_pkg::f_to_int(a2, rvv_softfloat_pkg::RM_RTZ, 1'b1, 32);
          VFCVT_F_XU:      r = rvv_softfloat_pkg::f_from_int(a2, rm, 1'b0, 32);
          VFCVT_F_X:       r = rvv_softfloat_pkg::f_from_int(a2, rm, 1'b1, 32);
          // int16 -> fp32 (every int16 is exact in fp32, so frm is irrelevant)
          VFWCVT_F_XU:     r = rvv_softfloat_pkg::f_from_int(a2, rm, 1'b0, 16);
          VFWCVT_F_X:      r = rvv_softfloat_pkg::f_from_int(a2, rm, 1'b1, 16);
          // fp32 -> int16
          VFNCVT_XU_F:     r = rvv_softfloat_pkg::f_to_int(a2, rm, 1'b0, 16);
          VFNCVT_X_F:      r = rvv_softfloat_pkg::f_to_int(a2, rm, 1'b1, 16);
          VFNCVT_RTZ_XU_F: r = rvv_softfloat_pkg::f_to_int(a2, rvv_softfloat_pkg::RM_RTZ, 1'b0, 16);
          VFNCVT_RTZ_X_F:  r = rvv_softfloat_pkg::f_to_int(a2, rvv_softfloat_pkg::RM_RTZ, 1'b1, 16);
          default:         `uvm_error("MDL/FP", $sformatf("vfunary0 vs1=%0d is not supported", inst_tr.src1_idx))
        endcase
      end
      // Reductions: dest holds the running value (vs1[0] to start with), src2 the next element --
      VFREDOSUM,
      VFREDUSUM: r = rvv_softfloat_pkg::f_add(ad, a2, rm);
      VFREDMIN:  r = rvv_softfloat_pkg::f_minmax(ad, a2, 1'b0);
      VFREDMAX:  r = rvv_softfloat_pkg::f_minmax(ad, a2, 1'b1);
      default: `uvm_error("MDL/FP", $sformatf("pc=0x%8x: %s is not a supported floating point instruction", inst_tr.pc, inst_tr.alu_inst.name()))
    endcase

    fflags = r.fl;
    return alu_unsigned_t'(r.val);
  endfunction: exe

endclass: fp_processor

`endif // RVV_FP_MODEL
