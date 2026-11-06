`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`define HDL_VERILOG_RVV_DESIGN_RVV_SVH

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH
`include "rvv_backend_define.svh"
`endif  // not defined HDL_VERILOG_RVV_DESIGN_RVV_DEFINE_SVH

`ifndef HDL_VERILOG_RVV_OPCODE_SVH
`include "rvv_backend_opcode.svh"
`endif // HDL_VERILOG_RVV_OPCODE_SVH

// Wrapper Parameterising Types over RVV Parameters

//
// IF stage, RVS send instruction package to Command Queue
//

// Enum type for SEW. See Table 2 in:
// https://github.com/riscv/riscv-v-spec/blob/master/v-spec.adoc#341-vector-selected-element-width-vsew20
typedef enum logic [2:0] {
  SEW8=0,
  SEW16=1,
  SEW32=2,
  SEW64=3
} RVVSEW_e;

// Enum type for LMUL. See:
// https://github.com/riscv/riscv-v-spec/blob/master/v-spec.adoc#vector-instruction-formats
typedef enum logic [2:0] {
  LMUL1=0,
  LMUL2=1,
  LMUL4=2,
  LMUL8=3,
  LMULRESERVED=4,
  LMUL1_8=5, // 1/8
  LMUL1_4=6, // 1/4
  LMUL1_2=7  // 1/2
} RVVLMUL_e;

// Enum type for vtype.vxrm: rounding mode
typedef enum logic [1:0] {
  RNU = 0,
  RNE = 1,
  RDN = 2,
  ROD = 3
} RVVXRM_e;

// Floating-point Rounding Mode
typedef enum logic [2:0] {
  FRNE=0,
  FRTZ=1,
  FRDN=2,
  FRUP=3,
  FRMM=4,
  FR_UNREACH_5=5,
  FR_UNREACH_6=6,
  FRDYN=7
} RVFRM_e;

// Floating-point Exception
typedef struct packed {
  logic nv;
  logic dz;
  logic of;
  logic uf;
  logic nx;
} RVFEXP_t;

// The architectural configuration state of the RVV core - parameterised over VLEN
// - vill: This configuration is illegal
// - vl: Max 128, need one extra bit
// - ma: 0:inactive element undisturbed, 1:inactive element agnostic
// - ta: 0:tail undisturbed, 1:tail agnostic
// - xsat: rvv dont need this bit, but output this to rvs
// - ZVT_ON:
//   - altfmt: Construct the vtype CSR value. See section 3.4 of the RISC-V Vector Specification v1.0, and
//   section 12.1.1.4 of the Zvt Specification (bit 8 = altfmt).
//   - mtwiden, tm, tk: VME (Zvt) non-tile state. Packed mtype view assembled from {tm, tk,
//      mtwiden} per 12.1.1.2.
//      Note: The spec defines tk as tk[2:0] (3 bits, values 0-4) in bits 7:5.
//      tm is in [23:10] (14 bits), mtwiden is in [1:0] (2 bits).
//
`define CONFIG_STATE_t(VLEN) \
struct packed { \
  logic                           vill; \
  logic [`VL_WIDTH(VLEN):0]       vl; \
  logic [`VSTART_WIDTH(VLEN)-1:0] vstart; \
  logic [`VTYPE_VMA_WIDTH-1:0]    ma; \
  logic [`VTYPE_VTA_WIDTH-1:0]    ta; \
  RVVXRM_e                        xrm; \
  logic [`VCSR_VXSAT_WIDTH-1:0]   xsat; \
`ifdef ZVE32F_ON \
  RVFRM_e                         frm; \
`endif \
  RVVSEW_e                        sew; \
  RVVLMUL_e                       lmul; \
  RVVLMUL_e                       lmul_orig; \
`ifdef ZVT_ON \
  logic                           altfmt; \
  logic [1:0]                     mtwiden; \
  logic [13:0]                    tm; \
  logic [2:0]                     tk; \
`endif \
}

// Enum to encode the major opcode of the instruction. See "Section 5. Vector
// Instruction Formats" of the RVV 1.0 spec.
typedef enum logic [1:0] {
  LOAD=0,
  STORE=1,
  RVV=2
} OPCODE_t;

// A decoded instruction forwarded to the RVVCore from the scalar core.
// - opcode: effectively bits [6:0] from instruction
// - bits: bits [31:7] from instruction
`define INSTRUCTION_t(PC_WIDTH) \
struct packed { \
  logic [`ROB_TAG_WIDTH-1:0] rob_tag; \
  logic [PC_WIDTH-1:0]      pc; \
  OPCODE_t                   opcode; \
  logic [24:0]               bits; \
}

// An command internal to the RVVCore. The immediate value of this command has
// been read from the scalar register file if necessary. It also contains
// additional data to track configuration register state (ie: SEW, LMUL, etc).
`define CMD_t(VLEN, XLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]       inst_pc; \
`endif \
  logic [`ROB_TAG_WIDTH-1:0] rob_tag; \
  OPCODE_t                   opcode; \
  logic [24:0]               bits; \
  logic [XLEN-1:0]           rs1; \
  `CONFIG_STATE_t(VLEN)      arch_state; \
}

//
// DE stage, Command Queue to Uops Queue
//
// Effective MUL enum
typedef enum logic [3:0] {
  EMUL1=0,
  EMUL2=1,
  EMUL4=2,
  EMUL8=3,
  EMUL3,
  EMUL5,
  EMUL6,
  EMUL7,
  EMUL_NONE     // it means this is not supported
} EMUL_e;

// Effective Element Width
typedef enum logic [2:0] {
  EEW_NONE,    // it means this is not supported
  EEW1,
  EEW8,
  EEW16,
  EEW32,
  EEW64
} EEW_e;

// the legal CMD_t after decoding
`define LCMD_t(VLEN, XLEN, PC_WIDTH) \
struct packed { \
  `CMD_t(VLEN, XLEN, PC_WIDTH)    cmd; \
  EEW_e                           eew_vs1; \
  EEW_e                           eew_vs2; \
  EEW_e                           eew_vd; \
`ifdef ZVT_ON \
  EEW_e                           eew_mt; \
`endif \
  EEW_e                           eew_max; \
  EMUL_e                          emul_vs1; \
  EMUL_e                          emul_vs2; \
  EMUL_e                          emul_vd; \
  EMUL_e                          emul_max; \
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_vstart; \
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_index_max; \
  logic   [`VL_WIDTH(VLEN)-1:0]  evl; \
  logic                           force_vma_agnostic; \
  logic                           force_vta_agnostic; \
}

// execution unit
typedef enum logic [4:0] {
  VEU_ALU,
  VEU_MUL,
  VEU_MAC,
  VEU_PMT,
  VEU_RDT,
  VEU_CMP,
  VEU_DIV,
  LSU,
`ifdef ZVE32F_ON
  VEU_FMA,
  VEU_FCVT,
  VEU_FRDT,
  VEU_FNCMP,
  VEU_FCMP,
  VEU_FDIV,
  VEU_FTBL,
`endif
`ifdef ZVT_ON
  VME,
  VMELSU,
`endif
  VEU_MISC
} EXE_UNIT_e;

// when EXE_UNIT_e is LSU, it identifys what LSU instruction, unit-stride load or indexed store or ..? based on inst_encoding[31:26]
typedef enum logic [2:0] {
  US,         // Unit-Stride
  IU,         // Indexed Unordered
  CS,         // Constant Stride
  IO          // Indexed Ordered
`ifdef ZVT_ON
  ,TILELDST
`endif
} LSU_MOP_e;

// It identifys what unit-stride instruction when LSU_MOP_e=US, based on inst_encoding[24:20]
typedef enum logic [1:0] {
  US_US,         // Unit-Stride load/store
  US_WR,         // Whole Register load/store
  US_MK,         // MasK load/store, EEW=8(inst_encoding[14:12]=3'b000)
  US_FF          // Faul-only-First load
} LSU_UMOP_e;

// segment load/store
typedef enum logic [0:0] {
  IS_SEGMENT,
  NONE
} LSU_IS_SEG_e;

// combine those signals to LSU_TYPE
typedef struct packed {
  LSU_MOP_e         lsu_mop;
  LSU_UMOP_e        lsu_umop;
  LSU_IS_SEG_e      lsu_is_seg;
} LSU_TYPE_t;

// function opcode
typedef union packed {
  logic   [`FUNCT6_WIDTH-1:0]         ari_funct6;
  LSU_TYPE_t                          lsu_funct6;
} FUNCT6_u;

// uop classification used for dispatch rule
typedef enum logic [2:0] {
  XXX=0,
  XXV=1,
  XVX=2,
  XVV=3,
  VXX=4,
  VXV=5,
  VVX=6,
  VVV=7
} UOP_CLASS_e;

// Destination data struct
typedef enum logic [1:0] {
  NOWRITE,
  VRF,
  XRF
`ifdef ZVE32F_ON
  ,FRF
`endif
} W_DATA_TYPE_e;

// the uop struct stored in Uops Queue
`define UOP_QUEUE_t(VLEN, XLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]          uop_pc; \
`endif \
  logic                           res_updating_end; \
  logic   [`ROB_TAG_WIDTH-1:0]    rob_tag; \
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3; \
  FUNCT6_u                        uop_funct6; \
  EXE_UNIT_e                      uop_exe_unit; \
  UOP_CLASS_e                     uop_class; \
  logic                           lsu_is_store; \
  `CONFIG_STATE_t(VLEN)           vector_csr; \
  logic   [`VL_WIDTH(VLEN)-1:0]   vs_evl; \
  logic                           ignore_vma; \
  logic                           ignore_vta; \
  logic                           force_vma_agnostic; \
  logic                           force_vta_agnostic; \
  logic                           vm; \
  logic                           v0_valid; \
  logic   [`REGIDX_WIDTH-1:0]     dst_index; \
  EEW_e                           vd_eew; \
  logic                           vd_valid; \
  logic                           vs3_valid; \
  logic                           xd_valid; \
`ifdef ZVE32F_ON \
  logic                           fd_valid; \
`endif \
`ifdef ZVT_ON \
  logic                           mt_valid; \
  EEW_e                           mt_eew; \
`endif \
  logic   [`REGIDX_WIDTH-1:0]     vs1; \
  EEW_e                           vs1_eew; \
  logic                           vs1_valid; \
  logic   [`REGIDX_WIDTH-1:0]     vs2_index; \
  EEW_e                           vs2_eew; \
  logic                           vs2_valid; \
  logic   [XLEN-1:0]              rs1_data; \
  logic                         rs1_data_valid; \
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_index; \
  logic                           first_uop_valid; \
  logic                           last_uop_valid; \
  logic   [$clog2(`EMUL_MAX)-1:0] seg_field_index; \
  logic                           pshrob_valid; \
  logic                           pshlsu_valid; \
}

// specify whether the current byte belongs to 'prestart' or 'body-inactive' or 'body-active' or 'tail'
typedef enum logic [1:0] {
  NOT_CHANGE    = 2'b00,      // the byte is not changed, which may belong to 'prestart' or
                              // superfluous element in widening/narrowing uop
  TAIL          = 2'b01,      // tail byte
  BODY_INACTIVE = 2'b10,      // body-inactive byte
  BODY_ACTIVE   = 2'b11       // body-active byte
} BYTE_TYPE_e;

// trap handle
typedef enum logic [1:0] {
  TRAP_LSU,
  TRAP_LSU_FF
} TRAP_INFO_e;

// the max number of byte in a vector register is VLENB
`define BYTE_TYPE_t(VLEN) BYTE_TYPE_e [`VLENB(VLEN)-1:0]

`define ALU_RS_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  logic                               is_cmp; \
  logic   [`VSTART_WIDTH(VLEN)-1:0]   vstart; \
  logic   [`VL_WIDTH(VLEN)-1:0]       vl; \
  logic                               vm; \
  RVVXRM_e                            vxrm; \
  logic   [VLEN-1:0]                  v0_data; \
  logic                               v0_data_valid; \
  logic   [VLEN-1:0]                  vd_data; \
  logic                               vd_data_valid; \
  EEW_e                               vd_eew; \
  logic   [`REGIDX_WIDTH-1:0]         vs1; \
  logic   [VLEN-1:0]                  vs1_data; \
  logic                               vs1_data_valid; \
  logic                               rs1_data_valid; \
  logic   [VLEN-1:0]                  vs2_data; \
  logic                               vs2_data_valid; \
  EEW_e                               vs2_eew; \
  logic                               first_uop_valid; \
  logic                               last_uop_valid; \
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index; \
}

// DIV reservation station struct
`define DIV_RS_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  logic                               is_div; \
  logic   [VLEN-1:0]                  vs1_data; \
  logic                               vs1_data_valid; \
  logic                               rs1_data_valid; \
  logic   [VLEN-1:0]                  vs2_data; \
  logic                               vs2_data_valid; \
  EEW_e                               vs2_eew; \
`ifdef ZVE32F_ON \
  RVFRM_e frm; \
  logic   [`REGIDX_WIDTH-1:0]         vs1; \
`endif \
}

// DIV reservation station struct
`define DIV_SUB_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  logic   [VLEN-1:0]                  vs1_data; \
  logic                               vs1_data_valid; \
  logic                               rs1_data_valid; \
  logic   [VLEN-1:0]                  vs2_data; \
  logic                               vs2_data_valid; \
  EEW_e                               vs2_eew; \
`ifdef ZVE32F_ON \
  RVFRM_e frm; \
  logic   [`REGIDX_WIDTH-1:0]         vs1; \
`endif \
}

// MUL and MAC reservation station struct
`define MUL_RS_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  RVVXRM_e vxrm; \
  logic   [VLEN-1:0]                  vs1_data; \
  logic                               vs1_data_valid; \
  logic          	                    rs1_data_valid; \
  logic   [VLEN-1:0]                  vs2_data; \
  logic                               vs2_data_valid; \
  EEW_e                               vs2_eew; \
  logic   [VLEN-1:0]                  vs3_data; \
  logic                               vs3_data_valid; \
  logic                               uop_index; \
}

// PMT and RDT reservation station struct
`define PMT_RDT_RS_t(VLEN, XLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  EXE_UNIT_e                          uop_exe_unit; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  logic   [`VL_WIDTH(VLEN)-1:0]              vl; \
  logic                               vm; \
  logic   [`VL_WIDTH(VLEN)-1:0]              vlmax; \
  logic   [VLEN-1:0]                  v0_data; \
  EEW_e                               vs1_eew; \
  logic   [VLEN-1:0]                  vs1_data; \
  logic                               vs1_data_valid; \
  EEW_e                               vs2_eew; \
  logic   [VLEN-1:0]                  vs2_data; \
  `BYTE_TYPE_t(VLEN)                  vs2_type; \
  logic   [`REGIDX_WIDTH-1:0]         vs2_index; \
  EEW_e                               vd_eew; \
  logic   [`REGIDX_WIDTH-1:0]         dst_index; \
  logic   [XLEN-1:0] 	                rs1_data; \
  logic                               first_uop_valid; \
  logic                               last_uop_valid; \
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index; \
`ifdef ZVE32F_ON \
  RVFRM_e frm; \
`endif \
}

// LSU reservation station struct
// - vidx_data: vs2
// - vregfile_read_data: vs3
// - v0_data: byte strobe signal for mask load/store.
//            v0[i]=1 means vd/vs3[8*i +: 8] data is valid.
`define UOP_RVV2LSU_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic                               vidx_valid; \
  logic   [`REGIDX_WIDTH-1:0]         vidx_addr; \
  logic   [VLEN-1:0]                  vidx_data; \
  logic                               vregfile_read_valid; \
  logic   [`REGIDX_WIDTH-1:0]         vregfile_read_addr; \
  logic   [VLEN-1:0]                  vregfile_read_data; \
  logic                               v0_valid; \
  logic   [`VLENB(VLEN)-1:0]          v0_data; \
}

// FMA reservation station struct
`define FALU_RS_t(VLEN, XLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]               uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]       rob_entry; \
  FUNCT6_u                             uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]          uop_funct3; \
  EXE_UNIT_e                           uop_exe_unit; \
  logic   [`VSTART_WIDTH(VLEN)-1:0]    vstart; \
  logic   [`VL_WIDTH(VLEN)-1:0]        vl; \
  logic                                vm; \
  RVFRM_e                                frm; \
  logic   [`VLENW(VLEN)*`EMUL_MAX-1:0] v0_data; \
  logic                                v0_data_valid; \
  logic   [`REGIDX_WIDTH-1:0]          vs1; \
  logic   [VLEN-1:0]                   vs1_data; \
  logic                                vs1_data_valid; \
  logic   [VLEN-1:0]                   vs2_data; \
  logic                                vs2_data_valid; \
  EEW_e                                vs2_eew; \
  logic   [VLEN-1:0]                   vs3_data; \
  logic                                vs3_data_valid; \
  logic   [XLEN-1:0]                   rs1_data; \
  logic                                rs1_data_valid; \
  logic                                last_uop_valid; \
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]   uop_index; \
}


//
// EX stage,
//
// send PU's result to ROB
// - w_data: when w_type=XRF, w_data[XLEN-1:0] will store the scalar result
`define PU2ROB_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic     [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic     [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  logic     [VLEN-1:0]                  w_data; \
  logic                                 w_valid; \
  logic     [`VLENB(VLEN)-1:0]          vsaturate; \
`ifdef ZVE32F_ON \
  RVFEXP_t [`VLENB(VLEN)-1:0]           fpexp; \
`endif \
}

// lsu uop info to remap rob_entry for UOP_LSU2RVV_t
`define LSU_MAP_INFO_t(PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                uop_pc; \
`endif \
  logic                               valid; \
  logic [`ROB_DEPTH_WIDTH-1:0]        rob_entry; \
  logic                               lsu_is_store; \
  logic [`REGIDX_WIDTH-1:0]           vregfile_write_addr; \
}

// LSU feedback to RVV
// - TB_SUPPORT: To trace wave
// - vregfile: For load data
// - write_data: vd - vregfile_write_data[VLEN-1:ff_tail_index*8] is treated as TAIL.
// - lsu_vstore_last: Store done signal to help ROB retire the store uop
`define UOP_LSU2RVV_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_index; \
`endif \
  logic                               vregfile_write_valid; \
  logic	  [`REGIDX_WIDTH-1:0] 	      vregfile_write_addr; \
  logic	  [VLEN-1:0] 			      vregfile_write_data; \
  logic   [$clog2(`VLENB(VLEN)):0]    ff_tail_index; \
  logic                               lsu_vstore_last; \
}

`define UOP_LSU_t(VLEN, PC_WIDTH) \
struct packed { \
  `UOP_LSU2RVV_t(VLEN, PC_WIDTH)      uop_lsu2rvv; \
  logic                               trap_valid; \
}

// write data; w_data[XLEN-1:0] is
// scalar result if write type is XRF
`define RES_ROB_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]               uop_pc; \
`endif \
  logic                                w_valid; \
  logic [VLEN-1:0]                     w_data; \
  logic [$clog2(`VLENB(VLEN)):0]        ff_tail_index; \
  logic [`VLENB(VLEN)-1:0]             vsaturate; \
`ifdef ZVE32F_ON \
  RVFEXP_t [`VLENB(VLEN)-1:0]            fpexp; \
`endif \
}

// send uop to ROB
// - w_index: wr addr
// - w_type: write type: 0 for VRF, 1 for XRF
// - byte_type: wr Byte mask
// - vector_csr: Receive Vstart, vlen,... And need to update vcsr when trap
`define DP2ROB_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_TAG_WIDTH-1:0]        rob_tag; \
  logic                               res_updating_end; \
  logic   [`REGIDX_WIDTH-1:0]         w_index; \
  W_DATA_TYPE_e                       w_type; \
  `BYTE_TYPE_t(VLEN)                  byte_type; \
  logic                               is_ff; \
  `CONFIG_STATE_t(VLEN)               vector_csr; \
  logic                               last_uop_valid; \
}

// send ROB info to DP
// - valid: entry valid
// - w_valid: vd valid
// - w_index: vd addr
// - w_type: write type: 0 for VRF, 1 for XRF
// - w_data: when w_type=XRF, w_data[XLEN-1:0] will store the scalar result
// - byte_type: wr Byte mask
// - vector_csr: Receive Vstart, vlen,... And need to update vcsr when trap
`define ROB2DP_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic                               valid; \
  logic                               w_valid; \
  logic   [`REGIDX_WIDTH-1:0]         w_index; \
  W_DATA_TYPE_e                       w_type; \
  logic   [VLEN-1:0]                  w_data; \
  `BYTE_TYPE_t(VLEN)                  byte_type; \
  `CONFIG_STATE_t(VLEN)               vector_csr; \
}

// - w_valid: entry valid
// - w_index: vd addr
// - w_type: write type: 0 for VRF, 1 for XRF
// - w_data: when w_type=XRF, w_data[XLEN-1:0] will store the scalar result
// - vd_type: wr Byte mask
// - trap flag: whether this entry in a trap
// - vector_csr: Receive Vstart, vlen,... And need to update vcsr when trap
// - vxsatruate: Update saturation bit
`define ROB2RT_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]               uop_pc; \
`endif \
  logic [`ROB_TAG_WIDTH-1:0]           rob_tag; \
  logic                                res_updating_end; \
  logic                                last_uop_valid; \
  logic                                w_valid; \
  logic   [`REGIDX_WIDTH-1:0]          w_index; \
  logic   [VLEN-1:0]                   w_data; \
  W_DATA_TYPE_e                        w_type; \
  `BYTE_TYPE_t(VLEN)                   vd_type; \
  logic                                trap_flag; \
  `CONFIG_STATE_t(VLEN)                vector_csr; \
  logic   [`VLENB(VLEN)-1:0]           vxsaturate; \
`ifdef ZVE32F_ON \
  RVFEXP_t [`VLENB(VLEN)-1:0]            fpexp; \
`endif \
}

// the rob struct stored in ROB
// - valid: entry valid
// - uop_info: uOp Information
// - uop_res: uOp result
// - uop_done: uOp is finished
`define ROB_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic                               valid; \
  `DP2ROB_t(VLEN, PC_WIDTH)           uop_info; \
  `RES_ROB_t(VLEN, PC_WIDTH)          uop_res; \
  logic                               uop_done; \
  logic                               trap; \
}

//
// Retire stage
//
// write back to XRF/FRF
`define RT2RVS_t(XLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]        uop_pc; \
`endif \
  logic   [`ROB_TAG_WIDTH-1:0]  rob_tag; \
  logic   [`REGIDX_WIDTH-1:0]   rt_index; \
  logic   [XLEN-1:0]            rt_data; \
}

// write back to VRF
`define RT2VRF_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]        uop_pc; \
`endif \
  logic   [`REGIDX_WIDTH-1:0]   rt_index; \
  logic   [VLEN-1:0]            rt_data; \
  logic   [`VLENB(VLEN)-1:0]    rt_strobe; \
}

// ZVT
`ifdef ZVT_ON
`define UOP_VME2LSU_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]          uop_pc; \
  logic [2:0]                   uop_index; \
`endif \
  logic [VLEN-1:0]              r_data; \
}

`define UOP_LSU2VME_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]          uop_pc; \
  logic [2:0]                   uop_index; \
`endif \
  logic [VLEN-1:0]              w_data; \
}

`define TSS_t(VLEN) \
struct packed { \
  logic [$clog2(`NUM_MT)-1:0]   tile; \
  logic                         pattern; \
  logic [$clog2(`TE(VLEN))-1:0] index; \
}

typedef enum logic [1:0] {
  FPMUL,        // src2 is fp
  INTMUL,       // src2 is signed int
  UINTMUL       // src2 is unsigned int
} PEOPCODE_e;

`define ZVT_RS_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]            uop_pc; \
`endif \
  logic   [`ROB_TAG_WIDTH-1:0]      rob_tag; \
  logic   [`ROB_DEPTH_WIDTH-1:0]    rob_entry; \
  FUNCT6_u                          uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]       uop_funct3; \
  logic   [`REGIDX_WIDTH-1:0]       vs2; \
  logic                             is_lsu; \
  logic                             is_store; \
  logic   [`VSTART_WIDTH(VLEN)-1:0] vstart; \
  logic                             altfmt; \
  logic   [1:0]                     mtwiden; \
  logic   [13:0]                    tm; \
  logic   [$clog2(`TE(VLEN)):0]     vl; \
  logic   [2:0]                     tk; \
  RVVSEW_e                             sew; \
  EEW_e                             eew_mt; \
  fpnew_pkg::roundmode_e            rndMode; \
  `TSS_t(VLEN)                      tss; \
  logic   [VLEN-1:0]                vs1_data; \
  logic   [VLEN-1:0]                vs2_data; \
  logic   [`REGIDX_WIDTH-1:0]       dst_index; \
  logic                             first_uop_valid; \
  logic                             last_uop_valid; \
  logic   [$clog2(`EMUL_MAX)-1:0]   uop_index; \
}

`define PEVAINFO_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                                        uop_pc; \
`endif \
  logic [`TE(VLEN)/2*`COMPRATIO(VLEN)-1:0][`WORD_WIDTH-1:0]   va; \
  logic [`TE(VLEN)/2*`COMPRATIO(VLEN)-1:0][3:0]               vaMask; \
  fpnew_pkg::roundmode_e                                      rndMode; \
  PEOPCODE_e                                                  op; \
  logic                                                       opMod; \
  fpnew_pkg::fp_format_e                                      fsrcFmt; \
  fpnew_pkg::int_format_e                                     isrcFmt; \
  fpnew_pkg::fp_format_e                                      fdstFmt; \
  fpnew_pkg::int_format_e                                     idstFmt; \
  logic [$clog2(`NUM_MT)-1:0]                                 readMtIdx; \
  logic [$clog2(`PROCESS_DELAY(VLEN))-1:0]                          readMtId; \
  logic                                                       lastUopVld; \
}

`define PEVBINFO_t(VLEN) \
struct packed { \
  logic [`TE(VLEN)/2-1:0][`WORD_WIDTH-1:0]             vb; \
  logic [`TE(VLEN)/2-1:0][3:0]                         vbMask; \
}

`define BLKCMD_t(VLEN, PC_WIDTH) \
struct packed { \
  `PEVAINFO_t(VLEN, PC_WIDTH)    vaInfo; \
  `PEVBINFO_t(VLEN)              vbInfo; \
}

`define MULBULKTAG_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                          uop_pc; \
`endif \
  fpnew_pkg::roundmode_e                        rndMode; \
  PEOPCODE_e                                    op; \
  fpnew_pkg::fp_format_e                        fdstFmt; \
  fpnew_pkg::int_format_e                       idstFmt; \
  logic [$clog2(`NUM_MT)-1:0]                   readMtIdx; \
  logic [$clog2(`PROCESS_DELAY(VLEN))-1:0]      readMtId; \
  logic                                         lastUopVld; \
}

`define MULBULKRES_t(VLEN, PC_WIDTH) \
struct packed { \
  logic [`TE(VLEN)/2*`COMPRATIO(VLEN)-1:0][`TE(VLEN)/2-1:0][`WORD_WIDTH-1:0]  res; \
  logic [`TE(VLEN)/2*`COMPRATIO(VLEN)-1:0][`TE(VLEN)/2-1:0][3:0]              resMask; \
  fpnew_pkg::status_t                                                         status; \
  `MULBULKTAG_t(VLEN, PC_WIDTH)                                                     tag; \
}

`define ADDERTAG_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                               uop_pc; \
`endif \
  fpnew_pkg::status_t                                status; \
  logic [$clog2(`NUM_MT)-1:0]                        writeMtIdx; \
  logic [$clog2(`PROCESS_DELAY(VLEN))-1:0]                 writeMtId; \
  logic                                              lastUopVld; \
}

`define VME_RTCMD_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                                inst_pc; \
`endif \
  logic [`ROB_TAG_WIDTH-1:0]                          rob_tag; \
  logic                                               isStore; \
  logic                                               isLoad; \
  logic                                               isMv2Vme; \
  logic                                               isZero; \
  logic                                               isPe; \
  logic [$clog2(`NUM_MT)-1:0]                         mtIdx; \
  logic [$clog2(`TE(VLEN))-1:0]                       tssIndex; \
  logic                                               tssPattern; \
  EEW_e                                               eew_mt; \
}

`define MT_INFO_t(VLEN, PC_WIDTH) \
struct packed { \
  logic                                                                 Vld; \
`ifdef RVVI_ON \
  logic [PC_WIDTH-1:0]                                                  inst_pc; \
  fpnew_pkg::status_t                                                   status; \
  logic [3:0][$clog2(`NUM_MT)-1:0]                                      rvviMtIdx; \
  logic [3:0][`NUM_SUBTILE(VLEN)/2-1:0]                                 rvviSubVld; \
  logic [3:0][`NUM_SUBTILE(VLEN)/2-1:0][$clog2(`NUM_SUBTILE(VLEN))-1:0] rvviSubIdx; \
  logic [3:0][`NUM_SUBTILE(VLEN)/2-1:0][`SUBTILE_SIZE*8-1:0]            rvviData; \
`endif \
}

`ifdef RVVI_ON
`define MISC_RTINFO_t(PC_WIDTH) \
struct packed { \
  logic [PC_WIDTH-1:0]                               uop_pc; \
  logic [$clog2(`NUM_MT)-1:0]                         mtIdx; \
}

`define PE_RTINFO_t(PC_WIDTH) \
struct packed { \
  logic [PC_WIDTH-1:0]                                uop_pc; \
  logic [$clog2(`NUM_MT)-1:0]                         mtIdx; \
}
`endif

`define VMERT_t(VLEN, PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic [PC_WIDTH-1:0]                                      inst_pc; \
`endif \
  logic [`ROB_TAG_WIDTH-1:0]                                rob_tag; \
  logic                                                     isStore; \
  logic [3:0]                                               mtIdxVld; \
  logic [$clog2(`NUM_MT)-1:0]                               mtIdx; \
`ifdef RVVI_ON \
  fpnew_pkg::status_t                                       status; \
  logic [3:0][`NUM_SUBTILE(VLEN)-1:0][`SUBTILE_SIZE*8-1:0]  mtData; \
`endif \
}
`endif  // ZVT_ON

`endif  // HDL_VERILOG_RVV_DESIGN_RVV_SVH
