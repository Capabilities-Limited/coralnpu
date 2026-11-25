`ifndef VME_INTERFACE__SV
`define VME_INTERFACE__SV

`include "rvv_backend_define.svh"
`include "rvv_backend.svh"

`ifdef ZVT_ON
// The Zvt (VME) side of the backend: tile load/store data to and from the external LSU, and the
// retire information of the instructions that bypass the ROB. Everything is driven by the TB.
interface vme_interface (input bit clk, input bit rst_n);
  // tile store: data from the VME to the LSU
  logic                                       uop_vme2lsu_vld;
  `UOP_VME2LSU_t(`VLEN, `PC_WIDTH)            uop_vme2lsu;
  logic                                       uop_vme2lsu_rdy;   // TB
  // tile load: data from the LSU to the VME
  logic                                       uop_lsu2vme_vld;   // TB
  `UOP_LSU2VME_t(`VLEN, `PC_WIDTH)            uop_lsu2vme;       // TB
  logic                                       uop_lsu2vme_rdy;
  logic                                       vme_lsuflush_vld;  // TB
  logic                                       vme_lsuflush_rdy;
  // retire information
  logic                                       vmeRtVld;
  `VMERT_t(`VLEN, `PC_WIDTH)                  vmeRt;
  logic                                       vmeRtRdy;          // TB
  // architectural FP flags of the matrix unit, as the retire stage merges them into fcsr.fflags
  // (observed; driven by the top level from DUT internals)
  logic                                       zvt_fpexp_fire;
  RVFEXP_t                                    zvt_fpexp;

  // Reset values; vme_driver drives the tile load/store handshakes from then on. The TB never flushes
  // the VME LSU queues and always accepts retire records.
  initial begin
    uop_vme2lsu_rdy  = 1'b1;
    uop_lsu2vme_vld  = 1'b0;
    uop_lsu2vme      = '0;
    vme_lsuflush_vld = 1'b0;
    vmeRtRdy         = 1'b1;
  end
endinterface: vme_interface
`endif // ZVT_ON

`endif // VME_INTERFACE__SV
