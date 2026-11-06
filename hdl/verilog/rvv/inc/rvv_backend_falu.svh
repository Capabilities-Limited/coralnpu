`ifndef HDL_VERILOG_RVV_INC_FALU_SVH
`define HDL_VERILOG_RVV_INC_FALU_SVH

//FALU subunit struct,
`define FMA_SUB_t(PC_WIDTH) \
struct packed { \
  logic   [3:0]                       ftype; \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]              uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]      rob_entry; \
  FUNCT6_u                            uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]         uop_funct3; \
  logic                               is_fcmp; \
  RVFRM_e                             frm; \
  logic   [`REGIDX_WIDTH-1:0]         vs1; \
  logic   [`WORD_WIDTH-1:0]           src1; \
  logic                               src1_valid; \
  logic   [`WORD_WIDTH-1:0]           src2; \
  logic                               src2_valid; \
  EEW_e                               src2_eew; \
  logic   [`WORD_WIDTH-1:0]           src3; \
  logic                               src3_valid; \
  logic                               last_uop_valid; \
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index; \
}

// Tag struct
`define TAG_t(PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic     [PC_WIDTH-1:0]            uop_pc; \
`endif \
  logic     [`ROB_DEPTH_WIDTH-1:0]    rob_entry; \
}

`define FCMP_TAG_t(PC_WIDTH) \
struct packed { \
  `TAG_t(PC_WIDTH)                    com_tag; \
  logic                               is_fcmp; \
  logic   [`UOP_INDEX_WIDTH_ALU-1:0]  uop_index; \
  logic                               last_uop_valid; \
}

`define FCMP_INFO_t(VLEN) \
struct packed { \
  logic [`VSTART_WIDTH(VLEN)-1:0]     vstart; \
  logic [`VL_WIDTH(VLEN)-1:0]         vl; \
  logic                               vm; \
  logic [`VLENW(VLEN)*`EMUL_MAX-1:0]  v0; \
  logic [VLEN-1:0]                    vd; \
}

`define FCVT_TAG_t(PC_WIDTH) \
struct packed { \
  `TAG_t(PC_WIDTH)                    com_tag; \
  EEW_e                               eew_vd; \
  logic                               uop_index; \
}

// SUB stand for sub-unit in FMA
// send SUB result to ROB
typedef struct packed {
  logic     [`WORD_WIDTH-1:0]         w_data;
  RVFEXP_t    [3:0]                     fpexp;
} SUB2ROB_t;

`endif // HDL_VERILOG_RVV_INC_FALU_SVH
