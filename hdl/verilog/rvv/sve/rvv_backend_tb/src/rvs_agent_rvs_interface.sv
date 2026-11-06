`ifndef RVS_INTERFACE__SV
`define RVS_INTERFACE__SV

`include "rvv_backend_define.svh"
`include "rvv_backend.svh"

// rst_n is an `input` like the other interfaces. It was a `ref` port (so
// rvv_reset_test could write it), but Verilator does not track `ref` ports on
// interface instances: reads saw the t=0 value forever. That test now drives the
// top-level rst_n directly.
interface rvs_interface (input bit clk, input bit rst_n);

// vector instruction and scalar operand .
  logic         [`ISSUE_LANE-1:0] insts_valid_rvs2cq;
  `CMD_t(`VLEN, `XLEN, `PC_WIDTH) [`ISSUE_LANE-1:0] insts_rvs2cq;
  logic         [`ISSUE_LANE-1:0] insts_ready_cq2rvs;

// ROB dataout
  logic        [`NUM_RT_UOP-1:0]  rd_valid_rob2rt ;
  `ROB2RT_t(`VLEN, `PC_WIDTH) [`NUM_RT_UOP-1:0] rd_rob2rt;
  logic        [`NUM_RT_UOP-1:0]  rd_ready_rt2rob ;

// write back to VRF. These are internal signals after WAW-merge of RVV.
  `RT2VRF_t(VLEN, PC_WIDTH) [`NUM_RT_UOP-1:0] rt_vrf_data_rob2rt ;
  logic         [`NUM_RT_UOP-1:0] rt_vrf_valid_rob2rt;

// write back to XRF. RVS arbitrates write ports of XRF by itself.
  `RT2RVS_t(XLEN, PC_WIDTH)      [`NUM_RT_UOP-1:0] rt_xrf_rvv2rvs      ;
  logic         [`NUM_RT_UOP-1:0] rt_xrf_valid_rvv2rvs;
  logic         [`NUM_RT_UOP-1:0] rt_xrf_ready_rvs2rvv;

// RT to VCSR.vxsat
  logic   [`NUM_RT_UOP-1:0]                         wr_vxsat_valid; // for each uops
  logic   [`NUM_RT_UOP-1:0] [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;       // for each uops
  logic                                             wr_vxsat_ready; // for all uops

// exception handler
  // the vcsr of last retired uop in last cycle
  logic                           vcsr_valid;
  `CONFIG_STATE_t(`VLEN)          vector_csr;
  logic                           vcsr_ready;

// write back event (for each instruction)
  logic         [`NUM_RT_UOP-1:0] rt_uop;
  logic         [`NUM_RT_UOP-1:0] rt_last_uop;

// decode result of inst
  logic         [`NUM_DE_INST-1:0] inst_correct;
  logic         [`NUM_DE_INST-1:0] inst_discard;
  `CMD_t(`VLEN, `XLEN, `PC_WIDTH) [`NUM_DE_INST-1:0] inst_pkg_cq2de;

// rvv idle
  logic         rvv_idle;
endinterface: rvs_interface

`endif // RVS_INTERFACE__SV
