`ifndef DIV_DEFINE_SVH
`define DIV_DEFINE_SVH

`define DIV_RES_t(PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]          uop_pc; \
`endif \
  FUNCT6_u                        uop_funct6; \
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3; \
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry; \
  EEW_e                           vs2_eew; \
}

`ifdef ZVE32F_ON
`define FDIV_RES_t(PC_WIDTH) \
struct packed { \
`ifdef TB_SUPPORT \
  logic   [PC_WIDTH-1:0]          uop_pc; \
`endif \
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry; \
}
`endif

`endif // DIV_DEFINE_SVH
