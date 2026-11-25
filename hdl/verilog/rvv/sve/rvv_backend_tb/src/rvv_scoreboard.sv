`ifndef RVV_SCOREBOARD__SV
`define RVV_SCOREBOARD__SV

`include "rvv_backend.svh"
`include "rvv_backend_define.svh"

  `uvm_analysis_imp_decl(_rvs)
  `uvm_analysis_imp_decl(_mdl) 
  `uvm_analysis_imp_decl(_rvs_vrf)
  `uvm_analysis_imp_decl(_mdl_vrf) 
  `uvm_analysis_imp_decl(_lsu_mem)
  `uvm_analysis_imp_decl(_mdl_mem) 
  `uvm_analysis_imp_decl(_scb_ctrl) 


class rvv_scoreboard extends uvm_scoreboard;

  typedef virtual rvs_interface v_if1;
  v_if1 rvs_if;  

  uvm_analysis_imp_rvs #(rvs_transaction,rvv_scoreboard) rvs_imp;
  uvm_analysis_imp_mdl #(rvs_transaction,rvv_scoreboard) mdl_imp;
  uvm_analysis_imp_rvs_vrf #(vrf_transaction,rvv_scoreboard) rvs_vrf_imp;
  uvm_analysis_imp_mdl_vrf #(vrf_transaction,rvv_scoreboard) mdl_vrf_imp;
  uvm_analysis_imp_lsu_mem #(mem_transaction,rvv_scoreboard) lsu_mem_imp;
  uvm_analysis_imp_mdl_mem #(mem_transaction,rvv_scoreboard) mdl_mem_imp;
  uvm_analysis_imp_scb_ctrl #(rvs_transaction,rvv_scoreboard) ctrl_imp;

  rvs_transaction rt_queue_rvs[$];
  rvs_transaction rt_queue_mdl[$];
`ifdef ZVT_ON
  // model fflags of every Zvt instruction that retires through vmeRt, by pc (see final_phase)
  logic [4:0]     zvt_mdl_flags [int unsigned];
`endif
  vrf_transaction vrf_queue_rvs[$];
  vrf_transaction vrf_queue_mdl[$];
  mem_transaction mem_queue_lsu[$];
  mem_transaction mem_queue_mdl[$];
  // cycles the oldest model memory access has waited for its LSU counterpart (see mem_access_checker)
  localparam int unsigned MEM_LSU_LAG_MAX = 1000;
  int unsigned    mem_lsu_lag;

  rvs_transaction ctrl_tr;

  int rvv_total_inst;
  int rvv_executed_inst;
  int mdl_total_inst;
  int mdl_executed_inst;

  rvv_backend_test test_top;

  `uvm_component_utils(rvv_scoreboard)
	extern function new(string name = "rvv_scoreboard", uvm_component parent = null); 
	extern virtual function void build_phase (uvm_phase phase);
	extern virtual function void connect_phase (uvm_phase phase);
	extern virtual task main_phase(uvm_phase phase);
	extern virtual function void report_phase(uvm_phase phase);
	extern virtual function void final_phase(uvm_phase phase);
 	extern function void write_rvs(rvs_transaction tr);
	extern function void write_mdl(rvs_transaction tr);
  extern function void write_rvs_vrf(vrf_transaction tr);
  extern function void write_mdl_vrf(vrf_transaction tr);
  extern function void write_lsu_mem(mem_transaction tr);
  extern function void write_mdl_mem(mem_transaction tr);
	extern function void write_scb_ctrl(rvs_transaction tr);
	extern virtual task rt_checker();
	extern virtual task vrf_checker();
	extern virtual task mem_access_checker();

endclass: rvv_scoreboard


function rvv_scoreboard::new(string name = "rvv_scoreboard", uvm_component parent);
  super.new(name,parent);
endfunction: new

function void rvv_scoreboard::build_phase(uvm_phase phase);
  super.build_phase(phase);
  rvs_imp = new("rvs_imp", this);
  mdl_imp = new("mdl_imp", this);
  rvs_vrf_imp = new("rvs_vrf_imp", this);
  mdl_vrf_imp = new("mdl_vrf_imp", this);
  lsu_mem_imp = new("lsu_mem_imp", this);
  mdl_mem_imp = new("mdl_mem_imp", this);
  ctrl_imp = new("ctrl_imp", this);
  ctrl_tr = new("ctrl_tr");
  if(!$cast(test_top, uvm_root::get().find("uvm_test_top")))
    `uvm_fatal(get_type_name(),"Get uvm_test_top fail")
endfunction:build_phase

function void rvv_scoreboard::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if(!uvm_config_db#(v_if1)::get(this, "", "rvs_if", rvs_if)) begin
    `uvm_fatal("SCB/NOVIF", "No virtual interface specified for this agent instance")
  end
endfunction:connect_phase

task rvv_scoreboard::main_phase(uvm_phase phase);
  super.main_phase(phase);
  fork
    rt_checker();
    vrf_checker();
    mem_access_checker();
  join
endtask: main_phase 

function void rvv_scoreboard::report_phase(uvm_phase phase);
  super.report_phase(phase);
endfunction:report_phase

function void rvv_scoreboard::write_rvs(rvs_transaction tr);
  `uvm_info(get_type_name(), "get a wb inst from dut", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  rt_queue_rvs.push_back(tr);
endfunction

function void rvv_scoreboard::write_mdl(rvs_transaction tr);
  `uvm_info(get_type_name(), "get a wb inst from mdl", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  rt_queue_mdl.push_back(tr);
endfunction

function void rvv_scoreboard::write_rvs_vrf(vrf_transaction tr);
  `uvm_info(get_type_name(), "get a vrf check request from dut", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  vrf_queue_rvs.push_back(tr);
endfunction

function void rvv_scoreboard::write_mdl_vrf(vrf_transaction tr);
  `uvm_info(get_type_name(), "get a vrf check request from mdl", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  vrf_queue_mdl.push_back(tr);
endfunction

function void rvv_scoreboard::write_lsu_mem(mem_transaction tr);
  `uvm_info(get_type_name(), "get a mem access check request from lsu", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  mem_queue_lsu.push_back(tr);
endfunction

function void rvv_scoreboard::write_mdl_mem(mem_transaction tr);
  `uvm_info(get_type_name(), "get a mem access check request from mdl", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  mem_queue_mdl.push_back(tr);
endfunction

function void rvv_scoreboard::write_scb_ctrl(rvs_transaction tr);
  `uvm_info(get_type_name(), "get a ctrl transaction", UVM_HIGH)
  `uvm_info(get_type_name(), tr.sprint(), UVM_HIGH)
  ctrl_tr = tr;
endfunction

task rvv_scoreboard::rt_checker();
  rvs_transaction mdl_tr;
  rvs_transaction rvs_tr;

  int        rt_vrf_num;
  reg_idx_t  rvs_rt_vrf_index , mdl_rt_vrf_index ;
  vrf_byte_t rvs_rt_vrf_byte_strobe, mdl_rt_vrf_byte_strobe;
  vrf_t      rvs_rt_vrf_bit_strobe,  mdl_rt_vrf_bit_strobe;
  vrf_t      rvs_rt_vrf_data  , mdl_rt_vrf_data  ;
  vrf_t      mdl_rt_vrf_old;               // register value before the instruction (from MDL)
  vrf_t      rvs_cmp_data, mdl_cmp_data;   // data compared exactly: bytes both sides write
  bit        strobe_ok;

  string vreg_dut_val;
  string vreg_mdl_val;
  string mismatch_mark;

  int        rt_xrf_num;
  reg_idx_t  rvs_rt_xrf_index, mdl_rt_xrf_index;
  xrf_t      rvs_rt_xrf_data , mdl_rt_xrf_data ;
  reg_idx_t  rvs_rt_frf_index, mdl_rt_frf_index;
  xrf_t      rvs_rt_frf_data , mdl_rt_frf_data ;
  forever begin
    @(negedge rvs_if.clk);
    if(rt_queue_mdl.size() != rt_queue_rvs.size()) begin
      `uvm_fatal("RT_CHECKER","Retire inst number mismatch between DUT & MDL.");
    end
    while(rt_queue_rvs.size()>0 && rt_queue_mdl.size()>0) begin 
      rvs_tr = rt_queue_rvs.pop_front();
      mdl_tr = rt_queue_mdl.pop_front();

      `uvm_info("RT_RECORDER", $sformatf("\nRetire check start. ====================================================================================================\n"),UVM_LOW)
      `uvm_info("RT_RECORDER", $sformatf("Got retire transaction from DUT:\n%s",rvs_tr.sprint()),UVM_LOW)
      `uvm_info("RT_RECORDER", $sformatf("Got retire transaction from MDL:\n%s",mdl_tr.sprint()),UVM_LOW)

      // PC check
      // if(rvs_tr.pc !== mdl_tr.pc) begin
      //   `uvm_error("RT_CHECKER", $sformatf("Retire PC mismatch:\nDUT retired pc 0x%8x, \nMDL retired pc 0x%8x.", 
      //                                       rvs_tr.pc,
      //                                       mdl_tr.pc))
      // end

      // VRF check
      if(rvs_tr.rt_vrf_index.size() != mdl_tr.rt_vrf_index.size()) begin
        `uvm_error("RT_CHECKER", $sformatf("Retire VRF quantity mismatch:\nDUT retired %0d vregs, \nMDL retired %0d vregs.", 
                                            rvs_tr.rt_vrf_index.size(),
                                            mdl_tr.rt_vrf_index.size()))
      end else begin
        rt_vrf_num = rvs_tr.rt_vrf_index.size();
        for(int i=0; i<rt_vrf_num; i++) begin
          rvs_rt_vrf_index  = rvs_tr.rt_vrf_index.pop_front();
          rvs_rt_vrf_byte_strobe = rvs_tr.rt_vrf_strobe.pop_front();
          rvs_rt_vrf_data   = rvs_tr.rt_vrf_data.pop_front();
          mdl_rt_vrf_index  = mdl_tr.rt_vrf_index.pop_front();
          mdl_rt_vrf_byte_strobe = mdl_tr.rt_vrf_strobe.pop_front();
          mdl_rt_vrf_data   = mdl_tr.rt_vrf_data.pop_front();
          // Since RTL use byte_strobe for retire, 
          //   MDL should generate byte_strobe, 
          //   and SCB also need to expand byte_strobe to bit_strobe to compare data.
          for(int bit_idx=0; bit_idx<`VLENB(VLEN); bit_idx++) begin
            rvs_rt_vrf_bit_strobe[bit_idx*8 +: 8] = {8{rvs_rt_vrf_byte_strobe[bit_idx]}}; 
            mdl_rt_vrf_bit_strobe[bit_idx*8 +: 8] = {8{mdl_rt_vrf_byte_strobe[bit_idx]}}; 
          end 
          // The RVV spec defines results by value ("unchanged" elements are not written), not by
          // write strobe. A byte that only one side writes is therefore acceptable if the data
          // written equals the register's previous value. Bytes both sides write must match.
          mdl_rt_vrf_old = 'x;
          if(mdl_tr.rt_vrf_old.size() > 0) mdl_rt_vrf_old = mdl_tr.rt_vrf_old.pop_front();
          strobe_ok = (rvs_rt_vrf_byte_strobe === mdl_rt_vrf_byte_strobe) ||
                      ((((rvs_rt_vrf_data ^ mdl_rt_vrf_old) & rvs_rt_vrf_bit_strobe & ~mdl_rt_vrf_bit_strobe) === '0) &&
                       (((mdl_rt_vrf_data ^ mdl_rt_vrf_old) & mdl_rt_vrf_bit_strobe & ~rvs_rt_vrf_bit_strobe) === '0));
          rvs_cmp_data = rvs_rt_vrf_data & rvs_rt_vrf_bit_strobe & mdl_rt_vrf_bit_strobe;
          mdl_cmp_data = mdl_rt_vrf_data & rvs_rt_vrf_bit_strobe & mdl_rt_vrf_bit_strobe;
          if(rvs_rt_vrf_index !== mdl_rt_vrf_index) begin
            `uvm_error("RT_CHECKER", $sformatf("Retire VRF index mismatch:\nDUT retired vrf[%0d],\nMDL retired vrf[%0d].", 
                                                rvs_rt_vrf_index, 
                                                mdl_rt_vrf_index));
          end else if(!strobe_ok) begin
            vreg_dut_val = "0x";
            vreg_mdl_val = "0x";
            // byte strobe has one bit per byte (VLENB bits), not VLEN bits
            for(int i=`VLENB(VLEN)-1;i>=0;i-=16) begin
              vreg_dut_val = $sformatf("%s%4h_",vreg_dut_val,rvs_rt_vrf_byte_strobe[i-:16]);
              vreg_mdl_val = $sformatf("%s%4h_",vreg_mdl_val,mdl_rt_vrf_byte_strobe[i-:16]);
            end
            vreg_dut_val = vreg_dut_val.substr(0,vreg_dut_val.len()-2);
            vreg_mdl_val = vreg_mdl_val.substr(0,vreg_mdl_val.len()-2);
            `uvm_error("RT_CHECKER", $sformatf("Retire VRF strobe(bit) mismatch:\nDUT retired vrf_strobe[%0d] = %s,\nMDL retired vrf_strobe[%0d] = %s.", 
                                               rvs_rt_vrf_index, vreg_dut_val,
                                               mdl_rt_vrf_index, vreg_mdl_val));
          end else if(rvs_cmp_data !== mdl_cmp_data) begin
            vreg_dut_val = "0x";
            vreg_mdl_val = "0x";
            mismatch_mark= "  ";
            for(int i=`VLEN-1;i>=0;i-=8) begin
              vreg_dut_val = $sformatf("%s%2h",vreg_dut_val,{rvs_cmp_data}[i-:8]);
              vreg_mdl_val = $sformatf("%s%2h",vreg_mdl_val,{mdl_cmp_data}[i-:8]);
              if({rvs_cmp_data}[i-:8] !== {mdl_cmp_data}[i-:8]) begin
                mismatch_mark = $sformatf("%s^^", mismatch_mark);
              end else begin
                mismatch_mark = $sformatf("%s  ", mismatch_mark);
              end
              if(i%16 == 7) begin
                vreg_dut_val = $sformatf("%s_",vreg_dut_val);
                vreg_mdl_val = $sformatf("%s_",vreg_mdl_val);
                mismatch_mark = $sformatf("%s ", mismatch_mark);
              end
            end
            vreg_dut_val = vreg_dut_val.substr(0,vreg_dut_val.len()-2);
            vreg_mdl_val = vreg_mdl_val.substr(0,vreg_mdl_val.len()-2);
            // `uvm_error("RT_CHECKER", $sformatf("Retire VRF mismatch:\nDUT retired vrf[%0d] = 0x%0x,\nMDL retired vrf[%0d] = 0x%0x.", 
            //                                     rvs_rt_vrf_index, (rvs_rt_vrf_bit_strobe & rvs_rt_vrf_data),
            //                                     mdl_rt_vrf_index, (mdl_rt_vrf_bit_strobe & mdl_rt_vrf_data)));
            `uvm_error("RT_CHECKER", {$sformatf("Retire VRF mismatch:\n"),
                                      $sformatf("DUT retired vrf[%2d] = %s\n",rvs_rt_vrf_index, vreg_dut_val),
                                      $sformatf("MDL retired vrf[%2d] = %s\n",mdl_rt_vrf_index, vreg_mdl_val), 
                                      $sformatf("mismatch_mark       = %s\n",mismatch_mark)});
          end else begin
            if(rvs_rt_vrf_byte_strobe !== mdl_rt_vrf_byte_strobe) begin
              `uvm_info("RT_CHECKER", $sformatf("Retire vrf[%0d]: write strobes differ (DUT 0x%0h, MDL 0x%0h), but the extra bytes carry the register's previous value.",
                                                rvs_rt_vrf_index, rvs_rt_vrf_byte_strobe, mdl_rt_vrf_byte_strobe), UVM_MEDIUM)
            end
            `uvm_info("RT_CHECKER", $sformatf("Retire vrf[%0d] check pass.",rvs_rt_vrf_index), UVM_LOW)
          end
        end
      end

      // XRF check
      if(rvs_tr.rt_xrf_index.size() != mdl_tr.rt_xrf_index.size()) begin
        `uvm_error("RT_CHECKER", $sformatf("Retire XRF quantity mismatch:\nDUT retired %0d xregs,\nMDL retired %0d xregs.", 
                                            rvs_tr.rt_xrf_index.size(),
                                            mdl_tr.rt_xrf_index.size()))
      end else begin
        rt_xrf_num = rvs_tr.rt_xrf_index.size();
        for(int i=0; i<rt_xrf_num; i++) begin
          rvs_rt_xrf_index  = rvs_tr.rt_xrf_index.pop_front();
          rvs_rt_xrf_data   = rvs_tr.rt_xrf_data.pop_front();
          mdl_rt_xrf_index  = mdl_tr.rt_xrf_index.pop_front();
          mdl_rt_xrf_data   = mdl_tr.rt_xrf_data.pop_front();
          if(rvs_rt_xrf_index !== mdl_rt_xrf_index) begin
            `uvm_error("RT_CHECKER", $sformatf("Retire XRF index mismatch:\nDUT retired xrf[%0d],\nMDL retired xrf[%0d].", 
                                                rvs_rt_xrf_index, 
                                                mdl_rt_xrf_index));
          end else if(rvs_rt_xrf_data !== mdl_rt_xrf_data) begin
            `uvm_error("RT_CHECKER", $sformatf("Retire XRF mismatch:\nDUT retired xrf[%0d] = 0x%8x,\nMDL retired xrf[%0d] = 0x%8x.", 
                                                rvs_rt_xrf_index, rvs_rt_xrf_data,
                                                mdl_rt_xrf_index, mdl_rt_xrf_data));
          end else begin
            `uvm_info("RT_CHECKER", $sformatf("Retire xrf[%0d] check pass.",rvs_rt_xrf_index), UVM_LOW)
          end
        end
      end

      // FRF check (vfmv.f.s)
      if(rvs_tr.rt_frf_index.size() != mdl_tr.rt_frf_index.size()) begin
        `uvm_error("RT_CHECKER", $sformatf("Retire FRF quantity mismatch:\nDUT retired %0d fregs,\nMDL retired %0d fregs.",
                                            rvs_tr.rt_frf_index.size(),
                                            mdl_tr.rt_frf_index.size()))
      end else begin
        while(rvs_tr.rt_frf_index.size() > 0) begin
          rvs_rt_frf_index  = rvs_tr.rt_frf_index.pop_front();
          rvs_rt_frf_data   = rvs_tr.rt_frf_data.pop_front();
          mdl_rt_frf_index  = mdl_tr.rt_frf_index.pop_front();
          mdl_rt_frf_data   = mdl_tr.rt_frf_data.pop_front();
          if(rvs_rt_frf_index !== mdl_rt_frf_index) begin
            `uvm_error("RT_CHECKER", $sformatf("Retire FRF index mismatch:\nDUT retired frf[%0d],\nMDL retired frf[%0d].",
                                                rvs_rt_frf_index, mdl_rt_frf_index));
          end else if(rvs_rt_frf_data !== mdl_rt_frf_data) begin
            `uvm_error("RT_CHECKER", $sformatf("Retire FRF mismatch:\nDUT retired frf[%0d] = 0x%8x,\nMDL retired frf[%0d] = 0x%8x.",
                                                rvs_rt_frf_index, rvs_rt_frf_data,
                                                mdl_rt_frf_index, mdl_rt_frf_data));
          end else begin
            `uvm_info("RT_CHECKER", $sformatf("Retire frf[%0d] check pass.",rvs_rt_frf_index), UVM_LOW)
          end
        end
      end

      // FFLAGS check: the DUT reports the flags per retiring uop, so the instruction's flags are the OR.
      if(rvs_tr.fflags !== mdl_tr.fflags) begin
        `uvm_error("RT_CHECKER", $sformatf("Retire fflags mismatch {NV,DZ,OF,UF,NX}:\nDUT fflags = 5'b%05b\nMDL fflags = 5'b%05b",
                                            rvs_tr.fflags, mdl_tr.fflags));
      end else if(mdl_tr.fflags !== 5'b0) begin
        `uvm_info("RT_CHECKER", $sformatf("Retire fflags check pass (5'b%05b).", mdl_tr.fflags), UVM_LOW)
      end

`ifdef ZVT_ON
      // Zvt tile check, against the model's destination tile (zvt_processor::snapshot): the bytes the
      // instruction wrote (body, and tail under the all-ones policy) must be in the byte-tiles the DUT
      // retires (vmeRt.mtIdxVld) and hold the model's value; every other byte of the destination tile
      // that the DUT retires must be unchanged (prestart, the rest of the tile around a row / column,
      // and the tail under the undisturbed policy).
      if(mdl_tr.is_zvt_vme) begin
        zvt_mdl_flags[mdl_tr.pc] = mdl_tr.fflags;
        if(!rvs_tr.rt_mt_valid) begin
          `uvm_error("RT_CHECKER", "Zvt instruction retired without vmeRt information.")
        end else begin
          int unsigned tile_bytes, nwritten, nbad_w, nbad_u, nmask, nchecked, nreported;
          int unsigned tew, ew_b, tl;
          tile_bytes = rvv_zvt_pkg::TILE_BYTES;
          nwritten = 0; nbad_w = 0; nbad_u = 0; nmask = 0; nchecked = 0; nreported = 0;
          if(mdl_tr.alu_inst inside {VTLE, VTSE})              tew = mdl_tr.zt_ew;   // TEW = EEW
          else if(mdl_tr.alu_inst inside {VTMV_T_V, VTMV_V_T}) tew = 8 << mdl_tr.vsew;
          else                                                 tew = (8 << mdl_tr.vsew) * (1 << (mdl_tr.mtwiden - 1));
          tl   = mdl_tr.exp_mt_ptile;
          ew_b = tew / 8;
          for(int unsigned b = 0; b < mdl_tr.exp_mt_val.size(); b += ew_b) begin
            // one element (ew_b bytes, never straddling a byte-tile) at a time
            int unsigned ptile, slot, off;
            bit in_rec, req, bad;
            ptile  = mdl_tr.exp_mt_ptile + b / tile_bytes;
            slot   = ptile - rvs_tr.rt_mt_idx;
            off    = ptile * tile_bytes + b % tile_bytes;
            in_rec = (ptile >= rvs_tr.rt_mt_idx) && (slot < 4) && rvs_tr.rt_mt_idxvld[slot];
            req    = 0;
            bad    = 0;
            for(int unsigned bi = 0; bi < ew_b; bi++) req |= mdl_tr.exp_mt_req[b + bi];
            if(req) nwritten += ew_b;
            if(!in_rec) begin
              if(req && nmask++ < 3)
                `uvm_info("RT_CHECKER", $sformatf("byte-tile %0d written by the model is not in the DUT retire mask %b (mtIdx=%0d).", ptile, rvs_tr.rt_mt_idxvld, rvs_tr.rt_mt_idx), UVM_NONE)
              continue;
            end
            nchecked += ew_b;
            for(int unsigned bi = 0; bi < ew_b; bi++) begin
              if(rvs_tr.rt_mt_val[slot * tile_bytes + b % tile_bytes + bi] !== mdl_tr.exp_mt_val[b + bi]) begin
                bad = 1;
                if(mdl_tr.exp_mt_req[b + bi]) nbad_w++; else nbad_u++;
              end
            end
            if(bad && nreported < 20) begin
              logic [63:0] dw, mw;
              int unsigned rr, cc;
              dw = 0; mw = 0;
              for(int unsigned bi = 0; bi < ew_b; bi++) begin
                dw[bi*8 +: 8] = rvs_tr.rt_mt_val[slot * tile_bytes + b % tile_bytes + bi];
                mw[bi*8 +: 8] = mdl_tr.exp_mt_val[b + bi];
              end
              if(rvv_zvt_pkg::zvt_locate(tl, tew, off, rr, cc))
                `uvm_info("RT_CHECKER", $sformatf("tile element mismatch (%s): C[%0d][%0d] (tew=%0d, byte-tile %0d offset 0x%03x): DUT %0h MDL %0h",
                                                  req ? "written" : "unchanged", rr, cc, tew, ptile, b % tile_bytes, dw, mw), UVM_NONE)
              nreported++;
            end
          end
          if(nbad_w != 0 || nbad_u != 0 || nmask != 0) begin
            `uvm_error("RT_CHECKER", $sformatf("Zvt tile mismatch (%s): %0d bytes written by the model differ, %0d bytes it left unchanged differ, %0d written outside the retire mask (%0d written, %0d checked).",
                                                 mdl_tr.asm_string, nbad_w, nbad_u, nmask, nwritten, nchecked))
          end else begin
            `uvm_info("RT_CHECKER", $sformatf("Zvt tile check pass (%0d bytes written, %0d checked).", nwritten, nchecked), UVM_LOW)
          end
        end
        // only needed for this check; drop them in case anything keeps the transactions
        rvs_tr.rt_mt_val.delete();
        mdl_tr.exp_mt_val.delete();
        mdl_tr.exp_mt_req.delete();
      end
`endif

      // VXSAT check
      if(rvs_tr.vxsat_valid !== mdl_tr.vxsat_valid) begin
        `uvm_error("RT_CHECKER","RVV vxsat_valid mismatch with reference model.");
      end else if(rvs_tr.vxsat_valid === 1 && mdl_tr.vxsat_valid === 1) begin
        if(rvs_tr.vxsat !== mdl_tr.vxsat) begin
          `uvm_error("RT_CHECKER", $sformatf("Retire vxsat mismatch:\nDUT vxsat = %0d\nMDL vxsat = %0d",
                                              rvs_tr.vxsat,
                                              mdl_tr.vxsat));
        end else begin
          `uvm_info("RT_CHECKER", "Writeback vxsat check pass.", UVM_LOW)
        end
      end

      // TRAP check
      if(rvs_tr.trap_occured !== mdl_tr.trap_occured) begin
        `uvm_error("RT_CHECKER","RVV trap_occured mismatch with reference model.");
      end else if(rvs_tr.trap_occured) begin
        if(rvs_tr.trap_vma !== mdl_tr.trap_vma) begin
          `uvm_error("RT_CHECKER","RVV trap_vma mismatch with reference model.");
        end else if(rvs_tr.trap_vta !== mdl_tr.trap_vta) begin
          `uvm_error("RT_CHECKER","RVV trap_vta mismatch with reference model.");
        end else if(rvs_tr.trap_vsew !== mdl_tr.trap_vsew) begin
          `uvm_error("RT_CHECKER","RVV trap_vsew mismatch with reference model."); 
        end else if(rvs_tr.trap_vlmul !== mdl_tr.trap_vlmul) begin
          `uvm_error("RT_CHECKER","RVV trap_vlmul mismatch with reference model.");
        end else if(rvs_tr.trap_vl !== mdl_tr.trap_vl) begin
          `uvm_error("RT_CHECKER","RVV trap_vl mismatch with reference model.");
        end else if(rvs_tr.trap_vstart !== mdl_tr.trap_vstart) begin
          `uvm_error("RT_CHECKER","RVV trap_vstart mismatch with reference model.");
        end else if(rvs_tr.trap_vxrm !== mdl_tr.trap_vxrm) begin
          `uvm_error("RT_CHECKER","RVV trap_vxrm mismatch with reference model.");
        end else begin
          `uvm_info("RT_CHECKER", "Trap check pass.", UVM_LOW)
        end 
      end
      `uvm_info("RT_RECORDER", $sformatf("\nRetire check done.  ====================================================================================================\n\n"),UVM_LOW)
    end
  end 
endtask: rt_checker 

task rvv_scoreboard::vrf_checker();
  vrf_transaction mdl_tr;
  vrf_transaction rvs_tr;
  int err;
  string vreg_dut_val;
  string vreg_mdl_val;
  forever begin
    @(negedge rvs_if.clk); 
    err = 0;
    if(vrf_queue_rvs.size()>1 || vrf_queue_mdl.size()>1) begin
      `uvm_error("TB_ISSUE", "Got more than 1 vrf check request, please check the TB.");
    end
    if(vrf_queue_rvs.size()>0 && vrf_queue_mdl.size()>0) begin
      rvs_tr = vrf_queue_rvs.pop_front();
      mdl_tr = vrf_queue_mdl.pop_front();
      `uvm_info("VRF_RECORDER", $sformatf("\nVRF check start. ====================================================================================================\n"),UVM_HIGH)
      for(int idx=0; idx<32; idx++) begin
        vreg_dut_val = "0x";
        vreg_mdl_val = "0x";
        if(rvs_tr.vreg[idx] !== mdl_tr.vreg[idx]) begin
          for(int i=`VLEN-1;i>=0;i-=16) begin
            vreg_dut_val = $sformatf("%s%4h_",vreg_dut_val,rvs_tr.vreg[idx][i-:16]);
            vreg_mdl_val = $sformatf("%s%4h_",vreg_mdl_val,mdl_tr.vreg[idx][i-:16]);
          end
          vreg_dut_val = vreg_dut_val.substr(0,vreg_dut_val.len()-2);
          vreg_mdl_val = vreg_mdl_val.substr(0,vreg_mdl_val.len()-2);
          //`uvm_warning("VRF_RECORDER", $sformatf("VRF[%0d] value mismatch: \ndut = 0x%0h \nmdl = 0x%0h", idx, rvs_tr.vreg[idx], mdl_tr.vreg[idx]))
          //`uvm_error("VRF_CHECKER", $sformatf("VRF[%0d] value mismatch: \ndut = 0x%0h \nmdl = 0x%0h", idx, rvs_tr.vreg[idx], mdl_tr.vreg[idx]))
          `uvm_warning("VRF_RECORDER", $sformatf("VRF[%0d] value mismatch: \ndut = %s \nmdl = %s", idx, vreg_dut_val, vreg_mdl_val))
          `uvm_error("VRF_CHECKER", $sformatf("VRF[%0d] value mismatch: \ndut = %s \nmdl = %s", idx, vreg_dut_val, vreg_mdl_val))
          err++;
        end
        `uvm_info("VRF_RECORDER", $sformatf("VRF[%0d] value: \ndut = 0x%0h \nmdl = 0x%0h", idx, rvs_tr.vreg[idx], mdl_tr.vreg[idx]), UVM_HIGH)
      end
      if(!err) begin
        `uvm_info("VRF_CHECKER", "VRF check pass", UVM_LOW)
      end
      `uvm_info("VRF_RECORDER", $sformatf("\nVRF check done.  ====================================================================================================\n"),UVM_HIGH)
    end
  end
endtask: vrf_checker 

task rvv_scoreboard::mem_access_checker();
  mem_transaction lsu_tr;
  mem_transaction mdl_tr;
  int err;
  forever begin
    @(negedge rvs_if.clk); 
    if(~rvs_if.rst_n) begin
      mem_queue_lsu.delete();
      mem_queue_mdl.delete();
      mem_lsu_lag = 0;
      err=0;
    end else begin
    err = 0;
    while(mem_queue_mdl.size()>0) begin
      if(mem_queue_lsu.size()>0) begin
        lsu_tr = mem_queue_lsu.pop_front();
        mdl_tr = mem_queue_mdl.pop_front();
        `uvm_info("MEM_RECORDER", $sformatf("\nMEM check start. ====================================================================================================\n"),UVM_HIGH)
        `uvm_info("MEM_RECORDER", "lsu memory tr:", UVM_HIGH)
        `uvm_info("MEM_RECORDER", lsu_tr.sprint(), UVM_HIGH)
        `uvm_info("MEM_RECORDER", "mdl memory tr:", UVM_HIGH)
        `uvm_info("MEM_RECORDER", mdl_tr.sprint(), UVM_HIGH)
        if(lsu_tr.kind != mdl_tr.kind) begin
          `uvm_error("MEM_CHCKER", $sformatf("Memory access kind mismatch: lsu = %s, mdl = %s", lsu_tr.kind.name(), mdl_tr.kind.name()))
          err++;
        end else begin
          `uvm_info("MEM_CHCKER", $sformatf("Memory access kind: lsu = %s, mdl = %s", lsu_tr.kind.name(), mdl_tr.kind.name()), UVM_HIGH)
        end
        if(lsu_tr.addr != mdl_tr.addr) begin
          `uvm_error("MEM_CHCKER", $sformatf("Memory access addr mismatch: lsu = 0x%8x, mdl = 0x%8x", lsu_tr.addr, mdl_tr.addr))
          err++;
        end else begin
          `uvm_info("MEM_CHCKER", $sformatf("Memory access addr: lsu = 0x%8x, mdl = 0x%8x", lsu_tr.addr, mdl_tr.addr), UVM_HIGH)
        end
        if(lsu_tr.data !== mdl_tr.data) begin
          `uvm_error("MEM_CHCKER", $sformatf("Memory access data mismatch: lsu = 0x%2x, mdl = 0x%2x", lsu_tr.data, mdl_tr.data))
          err++;
        end else begin
          `uvm_info("MEM_CHCKER", $sformatf("Memory access data: lsu = 0x%2x, mdl = 0x%2x", lsu_tr.data, mdl_tr.data), UVM_HIGH)
        end
        `uvm_info("MEM_RECORDER", $sformatf("\nMEM check done.  ====================================================================================================\n"),UVM_HIGH)
        mem_lsu_lag = 0;
      end else begin
        // The model executes an instruction when the DUT retires it, which is normally after the LSU
        // has done the accesses. Zvt tile stores are the exception: their data drains through the
        // vmelsu FIFO after vmeRt, so the LSU side may lag. Wait for it (this loop must consume time,
        // or it spins forever in one time step), but only for a bounded number of cycles.
        if(++mem_lsu_lag > MEM_LSU_LAG_MAX) begin
          mdl_tr = mem_queue_mdl.pop_front();
          `uvm_error("MEM_CHCKER", $sformatf("MDL has accessed memory but LSU hasn't within %0d cycles (pc=0x%08x %s addr=0x%08x data=0x%02x).",
                                             MEM_LSU_LAG_MAX, mdl_tr.pc, mdl_tr.kind.name(), mdl_tr.addr, mdl_tr.data))
          mem_lsu_lag = 0;
        end
        break;
      end
    end
    end
  end
  if(err == 0) begin
    `uvm_info("MEM_CHCKER", "Memory access check pass", UVM_LOW)
  end
endtask: mem_access_checker

function void rvv_scoreboard::final_phase(uvm_phase phase);
  super.final_phase(phase);

`ifdef ZVT_ON
  // Zvt: the architectural FP flags (what reaches fcsr.fflags), attributed per instruction by time
  // window in the monitor, against the model. Only meaningful with every instruction fenced.
  if($test$plusargs("zvt_fence_all") && zvt_mdl_flags.size() > 0) begin
    int unsigned npass, nfail;
    npass = 0; nfail = 0;
    foreach(zvt_mdl_flags[pc]) begin
      logic [4:0] arch;
      arch = rvs_transaction::zvt_arch_flags.exists(pc) ? rvs_transaction::zvt_arch_flags[pc] : 5'b0;
      // only NV and OF are defined for the matrix instructions; DZ/UF/NX must not be set
      if(arch !== zvt_mdl_flags[pc]) begin
        nfail++;
        if(nfail <= 20)
          `uvm_error("ZVT_ARCH_FFLAGS", $sformatf("pc=0x%08x: fflags reaching fcsr {NV,DZ,OF,UF,NX} = 5'b%05b, model 5'b%05b",
                                                   pc, arch, zvt_mdl_flags[pc]))
      end else begin
        npass++;
      end
    end
    `uvm_info("ZVT_ARCH_FFLAGS", $sformatf("architectural fflags of %0d Zvt instructions: %0d match the model, %0d do not.",
                                           npass + nfail, npass, nfail), UVM_NONE)
  end
`endif

  if(!uvm_config_db#(int)::get(uvm_root::get(), "", "rvv_total_inst", this.rvv_total_inst)) begin
    `uvm_fatal(get_type_name(), "Fail to get rvv_total_inst!")
  end
  if(!uvm_config_db#(int)::get(uvm_root::get(), "", "rvv_excuted_inst", this.rvv_executed_inst)) begin
    `uvm_fatal(get_type_name(), "Fail to get rvv_executed_inst!")
  end
  if(!uvm_config_db#(int)::get(uvm_root::get(), "", "mdl_total_inst", this.mdl_total_inst)) begin
    `uvm_fatal(get_type_name(), "Fail to get mdl_total_inst!")
  end
  if(!uvm_config_db#(int)::get(uvm_root::get(), "", "mdl_excuted_inst", this.mdl_executed_inst)) begin
    `uvm_fatal(get_type_name(), "Fail to get mdl_executed_inst!")
  end

  // Memory compare
  `uvm_info("FINAL_CHECK", "Checking memory...", UVM_LOW)
  foreach(test_top.env.lsu_agt.lsu_drv.mem.mem[idx]) begin
    if(test_top.env.lsu_agt.lsu_drv.mem.mem[idx] !== test_top.env.mdl.mem.mem[idx])
      `uvm_error("FINAL_CHECK", $sformatf("Memory mismatch: lsu_mem[0x%8x] = 0x%2x, mdl_mem[0x%8x] = 0x%2x.", idx, test_top.env.lsu_agt.lsu_drv.mem.mem[idx], idx, test_top.env.mdl.mem.mem[idx]))
  end
  `uvm_info("FINAL_CHECK", "Memory check pass.", UVM_LOW)

  // Queue check
  if(rt_queue_rvs.size()>0) begin
    `uvm_error("FINAL_CHECK", "rt_queue_rvs wasn't empty!")
    foreach(rt_queue_rvs[idx]) begin
      `uvm_error("FINAL_CHECK",rt_queue_rvs[idx].sprint())
    end
  end
  if(rt_queue_mdl.size()>0) begin
    `uvm_error("FINAL_CHECK", "rt_queue_mdl wasn't empty!")
    foreach(rt_queue_mdl[idx]) begin
      `uvm_error("FINAL_CHECK",rt_queue_mdl[idx].sprint())
    end
  end
  if(vrf_queue_rvs.size()>0) begin
    `uvm_error("FINAL_CHECK", "vrf_queue_rvs wasn't empty!")
    foreach(vrf_queue_rvs[idx]) begin
      `uvm_error("FINAL_CHECK",vrf_queue_rvs[idx].sprint())
    end
  end
  if(vrf_queue_mdl.size()>0) begin
    `uvm_error("FINAL_CHECK", "vrf_queue_mdl wasn't empty!")
    foreach(vrf_queue_mdl[idx]) begin
      `uvm_error("FINAL_CHECK",vrf_queue_mdl[idx].sprint())
    end
  end
  if(mem_queue_mdl.size()>0) begin
    `uvm_error("FINAL_CHECK", $sformatf("%0d model memory accesses were never matched by the LSU; oldest pc=0x%08x %s addr=0x%08x.",
                                        mem_queue_mdl.size(), mem_queue_mdl[0].pc, mem_queue_mdl[0].kind.name(), mem_queue_mdl[0].addr))
  end

  // Executed inst num check
  if(rvv_executed_inst !== mdl_executed_inst) begin
    `uvm_error("FINAL_CHECK", "Executed instruction number mismatch.")
  end
  `uvm_info(get_type_name(),"Exit final_phase...", UVM_HIGH)
endfunction: final_phase
`endif // RVV_SCOREBOARD__SV
