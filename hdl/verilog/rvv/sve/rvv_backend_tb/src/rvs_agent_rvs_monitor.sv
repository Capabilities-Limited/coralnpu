`ifndef RVS_MONITOR__SV
`define RVS_MONITOR__SV

`include "rvv_backend.svh"
typedef class rvs_transaction;
typedef class rvs_monitor;

  `uvm_analysis_imp_decl(_rvs_mon_inst)
  `uvm_blocking_get_imp_decl(_rvv_state)
class rvs_monitor extends uvm_monitor;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  uvm_analysis_imp_rvs_mon_inst #(rvs_transaction,rvs_monitor) inst_imp; 
  uvm_blocking_get_imp_rvv_state #(rvv_state_pkg::rvv_state_e, rvs_monitor) rvv_state_imp;

  uvm_analysis_port #(rvs_transaction) inst_ap; 
  uvm_analysis_port #(rvs_transaction) rt_ap;   
  uvm_analysis_port #(rvs_transaction) ctrl_ap; 

  typedef virtual rvs_interface v_if;
  typedef virtual rvv_intern_interface v_if4;
`ifdef ZVT_ON
  typedef virtual vme_interface v_if5;
  v_if5 vme_if;
`endif
  v_if rvs_if;
  v_if4 rvv_intern_if;

  rvs_transaction inst_tx_queue[$];
  rvs_transaction inst_rx_queue[$];
  rvs_transaction inst_temp_queue[$];

  rvs_transaction ctrl_tr;

  int total_inst = 0;
  int executed_inst = 0;

`ifdef ZVT_ON
  // Zvt retire bookkeeping
  int zvt_vme_accepted   = 0;   // Zvt instructions that retire through vmeRt, accepted by the backend
  int zvt_vmert_events   = 0;   // vmeRt handshakes seen
  int zvt_rt_pc_mismatch = 0;   // vmeRt handshakes whose inst_pc is not the oldest outstanding Zvt instruction
`endif

  int inst_tx_timeout_max = 500;
  int inst_tx_timeout_cnt = 0;

  bit use_tr_from_drv;

  `uvm_component_param_utils_begin(rvs_monitor)
  `uvm_component_utils_end

  extern function new(string name = "rvs_monitor",uvm_component parent);
  extern virtual function void build_phase(uvm_phase phase);
  extern virtual function void connect_phase(uvm_phase phase);
  extern virtual task reset_phase(uvm_phase phase);
  extern virtual task configure_phase(uvm_phase phase);
  extern virtual task run_phase(uvm_phase phase);
  extern virtual task main_phase(uvm_phase phase);
  extern virtual function void final_phase(uvm_phase phase);
  extern protected virtual task tx_monitor();
  extern protected virtual task rx_monitor();
  extern protected virtual task rx_timeout_monitor();
  extern protected virtual task idle_monitor();
`ifdef ZVT_ON
  extern protected virtual task zvt_flag_monitor();
`endif

  // imp task
  extern virtual function void write_rvs_mon_inst(rvs_transaction inst_tr);
  extern task get_rvv_state(output rvv_state_pkg::rvv_state_e rvv_state);

endclass: rvs_monitor


function rvs_monitor::new(string name = "rvs_monitor",uvm_component parent);
  super.new(name, parent);
endfunction: new

function void rvs_monitor::build_phase(uvm_phase phase);
  super.build_phase(phase);
  inst_imp = new("inst_imp", this);
  rvv_state_imp = new("rvv_state_imp", this);
  inst_ap = new ("inst_ap",this);
  rt_ap = new ("rt_ap",this);
  ctrl_ap = new("ctrl_ap", this);

  ctrl_tr = new("ctrl_tr");
  if($test$plusargs("use_tr_from_drv")) begin
    use_tr_from_drv = 1;
  end else begin
    use_tr_from_drv = 0;
  end
endfunction: build_phase

function void rvs_monitor::connect_phase(uvm_phase phase);
  super.connect_phase(phase);
  if(!uvm_config_db#(v_if)::get(this, "", "rvs_if", rvs_if))
    `uvm_fatal(get_type_name(), "Fail to get rvs_if!")
  if(!uvm_config_db#(v_if4)::get(this, "", "rvv_intern_if", rvv_intern_if))
    `uvm_fatal(get_type_name(), "Fail to get rvv_intern_if!")
`ifdef ZVT_ON
  if(!uvm_config_db#(v_if5)::get(this, "", "vme_if", vme_if))
    `uvm_fatal(get_type_name(), "Fail to get vme_if!")
`endif
  if(uvm_config_db#(int)::get(this, "", "inst_tx_timeout_max", inst_tx_timeout_max))
    `uvm_info(get_type_name(), $sformatf("inst_tx_timeout_max is set to = %0d",inst_tx_timeout_max), UVM_LOW)
  else begin
    inst_tx_timeout_max = 500;
    `uvm_info(get_type_name(), $sformatf("inst_tx_timeout_max is set to = %0d",inst_tx_timeout_max), UVM_LOW)
  end
endfunction: connect_phase

task rvs_monitor::reset_phase(uvm_phase phase);
  super.reset_phase(phase);
endtask: reset_phase

task rvs_monitor::configure_phase(uvm_phase phase);
  super.configure_phase(phase);
endtask:configure_phase

function void rvs_monitor::final_phase(uvm_phase phase);
  super.final_phase(phase);
  if(inst_rx_queue.size()>0) begin
    `uvm_error("FINAL_CHECK", "inst_rx_queue in RVS_MON wasn't empty!")
    foreach(inst_rx_queue[idx]) begin
      `uvm_error("FINAL_CHECK",inst_rx_queue[idx].sprint())
    end
  end
`ifdef ZVT_ON
  if(zvt_vme_accepted != 0 || zvt_vmert_events != 0) begin
    `uvm_info("FINAL_CHECK", $sformatf("Zvt: %0d instructions retire through vmeRt, %0d vmeRt records seen, %0d with an unexpected inst_pc.",
                                       zvt_vme_accepted, zvt_vmert_events, zvt_rt_pc_mismatch), UVM_NONE)
    if(zvt_vme_accepted != zvt_vmert_events)
      `uvm_error("FINAL_CHECK", $sformatf("Zvt: %0d vmeRt records for %0d instructions.", zvt_vmert_events, zvt_vme_accepted))
  end
`endif
  uvm_config_db#(int)::set(uvm_root::get(), "", "rvv_total_inst", this.total_inst);
  uvm_config_db#(int)::set(uvm_root::get(), "", "rvv_excuted_inst", this.executed_inst);
  `uvm_info("FINAL_CHECK", $sformatf("RVV total accepted inst: %0d, executed inst: %0d, discarded %.2f%%", 
                                      this.total_inst, this.executed_inst, real'(this.total_inst - this.executed_inst)*100.0/real'(this.total_inst)), UVM_NONE)
endfunction: final_phase 

task rvs_monitor::run_phase(uvm_phase phase);
  super.run_phase(phase);
  fork
     tx_monitor();
     rx_monitor();
     rx_timeout_monitor();
     idle_monitor();
`ifdef ZVT_ON
     zvt_flag_monitor();
`endif
  join
endtask: run_phase

task rvs_monitor::main_phase(uvm_phase phase);
  if(is_active) begin
    rvv_state_pkg::rvv_state_e rvv_state;
    phase.raise_objection( .obj( this ) );
    super.main_phase(phase);
    forever begin
      @(posedge rvs_if.clk);
      if(ctrl_tr.is_last_inst) begin
        get_rvv_state(rvv_state);
        if(inst_tx_queue.size()==0 && inst_rx_queue.size()==0 && inst_temp_queue.size()==0 && rvv_state==rvv_state_pkg::IDLE) begin 
          repeat(10) @(posedge rvs_if.clk);
          ctrl_ap.write(ctrl_tr);
          `uvm_info(get_type_name(), "ready to drop obj", UVM_HIGH)
          `uvm_info(get_type_name(), $sformatf("rvv state=%s", rvv_state), UVM_HIGH)
          repeat(10) @(posedge rvs_if.clk);
          break;
        end
      end
    end
    phase.drop_objection( .obj( this ) );
  end
endtask: main_phase

task rvs_monitor::tx_monitor();
  rvs_transaction inst_tr;
  rvs_transaction temp_tr;
  rvs_transaction rt_tr;
  forever begin
    @(posedge rvs_if.clk);
    if(~rvs_if.rst_n) begin
      inst_temp_queue.delete();
      inst_tx_queue.delete();
    end else begin
      for(int i=0; i<`ISSUE_LANE; i++) begin
        if(rvs_if.insts_valid_rvs2cq[i] && rvs_if.insts_ready_cq2rvs[i]) begin
          logic [31:0] inst_32;
          inst_tr = new("inst_tr");
          temp_tr = new("temp_tr");

          if(use_tr_from_drv && is_active) begin
            inst_tr = inst_tx_queue.pop_front();
          end else begin
            // Got inst from interface
            inst_tr.constraint_mode(0);
            inst_tr.set_config_state(
              rvs_if.insts_rvs2cq[i].arch_state.ma,
              rvs_if.insts_rvs2cq[i].arch_state.ta,
              rvs_if.insts_rvs2cq[i].arch_state.sew,
              rvs_if.insts_rvs2cq[i].arch_state.lmul,
              rvs_if.insts_rvs2cq[i].arch_state.vl,
              rvs_if.insts_rvs2cq[i].arch_state.vstart,
              rvs_if.insts_rvs2cq[i].arch_state.xrm
            );
`ifdef ZVE32F_ON
            inst_tr.frm = rvs_if.insts_rvs2cq[i].arch_state.frm;
`endif
`ifdef ZVT_ON
            inst_tr.mtwiden = rvs_if.insts_rvs2cq[i].arch_state.mtwiden;
            inst_tr.tm      = rvs_if.insts_rvs2cq[i].arch_state.tm;
            inst_tr.tk      = rvs_if.insts_rvs2cq[i].arch_state.tk;
            inst_tr.altfmt  = rvs_if.insts_rvs2cq[i].arch_state.altfmt;
`endif
            inst_32[31:7] = rvs_if.insts_rvs2cq[i].bits;
            case(rvs_if.insts_rvs2cq[i].opcode)
              2'b00: inst_32[6:0] = 7'b000_0111; // LOAD
              2'b01: inst_32[6:0] = 7'b010_0111; // STORE
              2'b10: inst_32[6:0] = 7'b101_0111; // ARI
            endcase
            inst_tr.bin2tr(inst_32, rvs_if.insts_rvs2cq[i].rs1);
`ifdef TB_SUPPORT
            inst_tr.pc = rvs_if.insts_rvs2cq[i].inst_pc;
`else
            inst_tr.pc = '0;
`endif

            if(is_active) begin
              inst_tr.is_last_inst = inst_tx_queue[0].is_last_inst;
`ifdef ZVT_ON
              // The address of a tile load/store stays with the scalar LSU and never reaches the
              // backend; take it from what the driver sent.
              if(inst_tr.is_zvt_inst && inst_tr.alu_inst inside {VTLE, VTSE}) inst_tr.zt_base = inst_tx_queue[0].zt_base;
`endif
              inst_tx_queue.pop_front();
            end
          end

          `uvm_info("INST_TR", inst_tr.sprint(),UVM_LOW)
          `uvm_info("ASM_DUMP",$sformatf("0x%8x\t%s", inst_tr.pc, inst_tr.asm_string),UVM_LOW)
          if(inst_tr.reserve_inst_check()) begin
            `uvm_info(get_type_name(), $sformatf("Send transaction to mdl:\n%s", inst_tr.sprint()), UVM_HIGH)
            inst_ap.write(inst_tr); // write to mdl/lsu
`ifdef ZVT_ON
            if(inst_tr.is_zvt_vme) zvt_vme_accepted++;
`endif
          end else begin 
            `uvm_info(get_type_name(), $sformatf("MON discarded inst:\n%s", inst_tr.sprint()), UVM_HIGH)
          end
          temp_tr.copy(inst_tr);
          `uvm_info(get_type_name(), $sformatf("Send transaction to inst_rx_queue:\n%s", inst_tr.sprint()), UVM_HIGH)
          inst_rx_queue.push_back(temp_tr);
          ctrl_tr = temp_tr;
          this.total_inst++;
        end
      end
      // for(int i=0; i<`NUM_DE_INST; i++) begin
      //   if(rvs_if.inst_correct[i]) begin
      //     rt_tr = new("rt_tr");
      //     rt_tr = inst_temp_queue.pop_front();
      //     inst_rx_queue.push_back(rt_tr);
      //     `uvm_info(get_type_name(), $sformatf("DUT will execute inst:\n%s",rt_tr.sprint()), UVM_HIGH)
      //   end else if(rvs_if.inst_discard[i]) begin
      //     rt_tr = new("rt_tr");
      //     rt_tr = inst_temp_queue.pop_front();
      //     `uvm_info(get_type_name(), $sformatf("DUT discarded inst:\n%s",rt_tr.sprint()), UVM_HIGH)
      //   end
      // end
    end
  end
endtask: tx_monitor

task rvs_monitor::rx_monitor();
  rvs_transaction tr, inst_tr;
  logic [`VLENB(VLEN)-1:0] rt_vrf_byte_strobe;
  logic [`VLEN-1:0] rt_vrf_bit_strobe;
  bit vrf_overlap;
  bit ready_to_new_inst;
  bit discard_found;
  int uop_cnt = 0;
  tr = new("tr");
  forever begin
    @(posedge rvs_if.clk);
    if(~rvs_if.rst_n) begin
      ready_to_new_inst = 1;
      uop_cnt = 0;
      inst_rx_queue.delete();
    end else begin
      // Remove discarded inst from inst_rx_queue
      for(int i=0; i<`NUM_DE_INST; i++) begin
        if(rvs_if.inst_discard[i]) begin
          logic [31:0] inst_32;
          inst_tr = new("inst_tr");
          inst_tr.constraint_mode(0);
          inst_tr.set_config_state(
            rvs_if.inst_pkg_cq2de[i].arch_state.ma,
            rvs_if.inst_pkg_cq2de[i].arch_state.ta,
            rvs_if.inst_pkg_cq2de[i].arch_state.sew,
            rvs_if.inst_pkg_cq2de[i].arch_state.lmul,
            rvs_if.inst_pkg_cq2de[i].arch_state.vl,
            rvs_if.inst_pkg_cq2de[i].arch_state.vstart,
            rvs_if.inst_pkg_cq2de[i].arch_state.xrm
          );
`ifdef ZVE32F_ON
          inst_tr.frm = rvs_if.inst_pkg_cq2de[i].arch_state.frm;
`endif
`ifdef ZVT_ON
          inst_tr.mtwiden = rvs_if.inst_pkg_cq2de[i].arch_state.mtwiden;
          inst_tr.tm      = rvs_if.inst_pkg_cq2de[i].arch_state.tm;
          inst_tr.tk      = rvs_if.inst_pkg_cq2de[i].arch_state.tk;
          inst_tr.altfmt  = rvs_if.inst_pkg_cq2de[i].arch_state.altfmt;
`endif
          inst_32[31:7] = rvs_if.inst_pkg_cq2de[i].bits;
          case(rvs_if.inst_pkg_cq2de[i].opcode)
            2'b00: inst_32[6:0] = 7'b000_0111; // LOAD
            2'b01: inst_32[6:0] = 7'b010_0111; // STORE
            2'b10: inst_32[6:0] = 7'b101_0111; // ARI
          endcase
          inst_tr.bin2tr(inst_32, rvs_if.inst_pkg_cq2de[i].rs1);
`ifdef TB_SUPPORT
          inst_tr.pc = rvs_if.inst_pkg_cq2de[i].inst_pc;
`else
          inst_tr.pc = '0;
`endif
          discard_found = 0;
          foreach(inst_rx_queue[idx]) begin
            if(inst_rx_queue[idx].compare_inst(inst_tr)) begin
              `uvm_info(get_type_name(), $sformatf("DUT discarded inst:\n%s", inst_rx_queue[idx].sprint()), UVM_HIGH)
              inst_rx_queue.delete(idx);
              discard_found = 1;
              break;
            end
          end
          if(!discard_found) begin
            foreach(inst_rx_queue[q]) begin
              `uvm_info(get_type_name(), $sformatf("  queued[%0d]: pc=0x%08x bin=0x%08x rs1=0x%08x vl=%0d vstart=%0d frm=%0d", q, inst_rx_queue[q].pc, inst_rx_queue[q].bin_inst, inst_rx_queue[q].rs1_data, inst_rx_queue[q].vl, inst_rx_queue[q].vstart, inst_rx_queue[q].frm), UVM_NONE)
            end
            `uvm_warning(get_type_name(), $sformatf("DUT discarded an instruction that matches nothing in inst_rx_queue (bin=0x%08x rs1=0x%08x):\n%s", inst_tr.bin_inst, inst_tr.rs1_data, inst_tr.sprint()))
          end
        end
      end

`ifdef ZVT_ON
      // Zvt instructions that bypass the ROB (matmuls, vtzero, vtmv.t.v, tile loads / stores) retire
      // through vmeRt. The driver fences between the two retire paths, so the head of the queue is the
      // instruction this event belongs to.
      if(vme_if.vmeRtVld && vme_if.vmeRtRdy) begin
        if(inst_rx_queue.size() == 0) begin
          `uvm_error("TB_ISSUE", "vmeRt retire while inst_rx_queue is empty.")
        end else if(!inst_rx_queue[0].is_zvt_vme) begin
          `uvm_info(get_type_name(), $sformatf("vmeRt for an instruction that retires through the ROB (pc=0x%08x, mtIdxVld=%b); ignored.", inst_rx_queue[0].pc, vme_if.vmeRt.mtIdxVld), UVM_MEDIUM)
        end else begin
          rvs_transaction vtr;
          vtr = inst_rx_queue.pop_front();
          zvt_vmert_events++;
`ifdef TB_SUPPORT
          // The record must belong to the oldest outstanding Zvt instruction
          if(vme_if.vmeRt.inst_pc !== vtr.pc[`PC_WIDTH-1:0]) begin
            zvt_rt_pc_mismatch++;
            `uvm_error("ZVT_RT_PC", $sformatf("vmeRt retires inst_pc=0x%08x, but the oldest outstanding Zvt instruction is pc=0x%08x (%s)",
                                              vme_if.vmeRt.inst_pc, vtr.pc, vtr.asm_string))
          end
`endif
          vtr.rt_mt_valid  = 1;
          vtr.rt_mt_idxvld = vme_if.vmeRt.mtIdxVld;
          vtr.rt_mt_idx    = vme_if.vmeRt.mtIdx;
          vtr.fflags      |= {vme_if.vmeRt.status};
          // slot i carries byte-tile mtIdx+i when mtIdxVld[i]
          vtr.rt_mt_val = new[4 * `TE(`VLEN) * `TE(`VLEN)];
          for(int i = 0; i < 4; i++) begin
            if(vme_if.vmeRt.mtIdxVld[i]) begin
              for(int s = 0; s < `NUM_SUBTILE(`VLEN); s++) begin
                for(int b = 0; b < `SUBTILE_SIZE; b++) begin
                  vtr.rt_mt_val[i * `TE(`VLEN) * `TE(`VLEN) + s * `SUBTILE_SIZE + b] = vme_if.vmeRt.mtData[i][s][b*8 +: 8];
                end
              end
            end
          end
          vtr.is_rt = 1;
          vtr.vxsat = '0;
          vtr.vxsat_valid = '0;
          `uvm_info(get_type_name(), $sformatf("Send vme rt transaction to scb: pc=0x%08x", vtr.pc), UVM_HIGH)
          rt_ap.write(vtr);
          this.executed_inst++;
        end
      end
`endif

      // Collect retire info
      for(int rt_idx=0; rt_idx<`NUM_RT_UOP; rt_idx++) begin
        if(rvs_if.rt_uop[rt_idx]) begin
          if(ready_to_new_inst) begin
            if(inst_rx_queue.size() == 0) begin
              `uvm_fatal("TB_ISSUE", "Retiring new inst while inst_rx_queue is empty.\n")
            end
            tr = new("tr");
            tr = inst_rx_queue.pop_front();
            ready_to_new_inst = 0;
            `uvm_info(get_type_name(), $sformatf("Ready to according retire info of new inst:\n%s", tr.sprint()), UVM_HIGH);
            uop_cnt = 0;
          end else begin
            uop_cnt++;
          end
          `uvm_info(get_type_name(), $sformatf("uops %0d of inst 0x%08x\n", uop_cnt, tr.pc), UVM_HIGH);

          // VRF
          if(rvs_if.rt_vrf_valid_rob2rt[rt_idx]) begin
            int pos = 0;
            vrf_overlap = 0;
            rt_vrf_byte_strobe = rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_strobe;
            for(int i=0; i<`VLENB(VLEN); i++) begin
              rt_vrf_bit_strobe[i*8 +: 8] = {8{rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_strobe[i]}}; 
            end 
            foreach(tr.rt_vrf_index[i]) begin
              // merge same vrf
              if(tr.rt_vrf_index[i] == rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_index) begin
                tr.rt_vrf_strobe[i] |= rt_vrf_byte_strobe;
                tr.rt_vrf_data[i]   = rt_vrf_bit_strobe & rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_data | ~rt_vrf_bit_strobe & tr.rt_vrf_data[i];
                vrf_overlap = 1;
                `uvm_info(get_type_name(), $sformatf("Uops %0d also write vrf[%0d].", rt_idx, rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_index), UVM_HIGH)
              end
              // sort vrf
              if(tr.rt_vrf_index[i] > rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_index) begin
                pos = i;
                break;
              end else begin
                pos = i+1;
              end
            end
            if(!vrf_overlap) begin
              tr.rt_vrf_index.insert(pos, rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_index);
              tr.rt_vrf_strobe.insert(pos, rt_vrf_byte_strobe);
              tr.rt_vrf_data.insert(pos, rvs_if.rt_vrf_data_rob2rt[rt_idx].rt_data);
            end
          end

          // XRF
          if(rvs_if.rt_xrf_valid_rvv2rvs[rt_idx] && rvs_if.rt_xrf_ready_rvs2rvv[rt_idx]) begin
            tr.rt_xrf_index.push_back(rvs_if.rt_xrf_rvv2rvs[rt_idx].rt_index);
            tr.rt_xrf_data.push_back(rvs_if.rt_xrf_rvv2rvs[rt_idx].rt_data);
          end

`ifdef ZVE32F_ON
          // FRF (vfmv.f.s)
          if(rvs_if.async_frd_valid[rt_idx] && rvs_if.async_frd_ready[rt_idx]) begin
            tr.rt_frf_index.push_back(rvs_if.async_frd_addr[rt_idx]);
            tr.rt_frf_data.push_back(rvs_if.async_frd_data[rt_idx]);
          end

          // FFLAGS: OR of every retiring uop of the instruction
          if(rvs_if.rt_fflags_valid[rt_idx]) begin
            tr.fflags |= rvs_if.rt_fflags[rt_idx];
          end
`endif

          // VXSAT
          if((tr.vxsat !== 1) && rvs_if.wr_vxsat_valid[rt_idx]) begin
            tr.vxsat        = rvs_if.wr_vxsat[rt_idx];
            tr.vxsat_valid  = rvs_if.wr_vxsat_valid[rt_idx];
          end else begin
            tr.vxsat        = tr.vxsat;
            tr.vxsat_valid  = tr.vxsat_valid;
          end

          // TRAP
          if(rvs_if.vcsr_valid && rvs_if.vcsr_ready) begin
            if(ready_to_new_inst) begin
              tr = new("tr");
              tr = inst_rx_queue.pop_front();
              ready_to_new_inst = 0;
            end
            tr.trap_occured = 1;
            tr.trap_vma     = rvs_if.vector_csr.ma;
            tr.trap_vta     = rvs_if.vector_csr.ta;
            assert($cast(tr.trap_vsew, rvs_if.vector_csr.sew)); 
            assert($cast(tr.trap_vlmul, rvs_if.vector_csr.lmul));
            tr.trap_vl      = rvs_if.vector_csr.vl;
            tr.trap_vstart  = rvs_if.vector_csr.vstart;
            assert($cast(tr.trap_vxrm, rvs_if.vector_csr.xrm));

            tr.is_rt = 1;
            // Avoid x-state
            if(tr.vxsat !== 1) tr.vxsat = '0;
            if(tr.vxsat_valid !== 1) tr.vxsat_valid = '0;
            // tr.is_last_inst = 1;
            `uvm_info(get_type_name(), $sformatf("Send rt transaction to scb"),UVM_HIGH)
            `uvm_info(get_type_name(), tr.sprint(),UVM_HIGH)
            rt_ap.write(tr); // write to scb
            ready_to_new_inst = 1;
            this.executed_inst++;

            // Clean reset inst
            inst_rx_queue.delete();
            inst_temp_queue.delete();
            continue;
          end

          // LAST_UOP
          if(rvs_if.rt_last_uop[rt_idx]) begin
            tr.is_rt = 1;
            // Avoid x-state
            if(tr.vxsat !== 1) tr.vxsat = '0;
            if(tr.vxsat_valid !== 1) tr.vxsat_valid = '0;
            // tr.is_last_inst = 1;
            `uvm_info(get_type_name(), $sformatf("Send rt transaction to scb"),UVM_HIGH)
            `uvm_info(get_type_name(), tr.sprint(),UVM_HIGH)
            rt_ap.write(tr); // write to scb
            ready_to_new_inst = 1;
            this.executed_inst++;
          end
        end
      end
    end
  end
endtask: rx_monitor

task rvs_monitor::rx_timeout_monitor();
  forever begin
    @(posedge rvs_if.clk);
    if(~rvs_if.rst_n) begin
      inst_tx_timeout_cnt = 0;
    end else begin
      // Timeout of inst port handshake check.
      if(|rvs_if.insts_valid_rvs2cq) begin
        inst_tx_timeout_cnt++;
      end
      if(|(rvs_if.insts_valid_rvs2cq & rvs_if.insts_ready_cq2rvs)) begin
        inst_tx_timeout_cnt = 0;
      end
      if(inst_tx_timeout_cnt >= inst_tx_timeout_max) begin
        `uvm_fatal(get_type_name(), $sformatf("Insts haven't been accepted by rvv for %0d cycles. Shut down!",inst_tx_timeout_cnt))
      end
    end
  end
endtask: rx_timeout_monitor

task rvs_monitor::idle_monitor();
  forever begin
    @(negedge rvs_if.clk);
    if(~rvs_if.rst_n) begin
      if(rvs_if.rvv_idle !== 1) begin
        `uvm_error(get_type_name(), "rvv_idle != 1 while rst_n == 0.")
      end
    end else begin
      if(rvs_if.rvv_idle && inst_rx_queue.size() != 0) begin
`ifdef ZVT_ON
        // Known RTL finding: for Zvt instructions that retire through vmeRt, rvv_idle rises while the
        // retire information is still held in the retire-command register stage and the mtInfo FIFOs
        // (zvtBusy does not cover them), so the backend reports idle one instruction early.
        // +zvt_waive_early_idle turns that case into a warning so the rest of the checking can run.
        if(inst_rx_queue[0].is_zvt_vme && $test$plusargs("zvt_waive_early_idle")) begin
          `uvm_warning("ZVT_IDLE_EARLY", $sformatf("rvv_idle is high while Zvt instruction pc=0x%08x has not retired yet.", inst_rx_queue[0].pc))
        end else begin
          `uvm_error(get_type_name(), $sformatf("Rvv in idle mode, but rvs monitor has instructions to wait for retire info."))
        end
`else
        `uvm_error(get_type_name(), $sformatf("Rvv in idle mode, but rvs monitor has instructions to wait for retire info."))
`endif
      end
    end
  end
endtask: idle_monitor

function void rvs_monitor::write_rvs_mon_inst(rvs_transaction inst_tr);
  `uvm_info(get_type_name(), "get a inst", UVM_HIGH)
  `uvm_info(get_type_name(), inst_tr.sprint(), UVM_HIGH)
  if(is_active) begin
    inst_tx_queue.push_back(inst_tr);
  end
endfunction

task rvs_monitor::get_rvv_state(output rvv_state_pkg::rvv_state_e rvv_state);
  if(rvv_intern_if.rvv_is_idle() === 1'b1)
    rvv_state = rvv_state_pkg::IDLE; 
  else if(rvv_intern_if.rvv_is_idle() === 1'b0)
    rvv_state = rvv_state_pkg::BUSY; 
  else
    rvv_state = rvv_state_pkg::UNKNOW;
endtask: get_rvv_state
`ifdef ZVT_ON
// Attribute the matrix unit's architectural FP flags (the ones that reach fcsr.fflags) to instructions.
// The events carry no tag, so this works by time: everything that arrives between the acceptance of
// one instruction and the next belongs to the first. That is only meaningful when every instruction is
// fenced (+zvt_fence_all): then a flag arriving after the next instruction was accepted means the flag
// reached fcsr after the backend had already gone idle, which the precise-state model does not allow.
task rvs_monitor::zvt_flag_monitor();
  logic [4:0]  acc;
  int unsigned cur_pc;
  bit          have_cur;
  // the attribution is only checked (scoreboard final_phase) with every instruction fenced; don't
  // build a per-instruction map otherwise
  if(!$test$plusargs("zvt_fence_all")) return;
  acc = '0;
  have_cur = 0;
  forever begin
    @(posedge rvs_if.clk);
    if(~rvs_if.rst_n) begin
      acc = '0;
      have_cur = 0;
    end else begin
      if(vme_if.zvt_fpexp_fire) acc |= {vme_if.zvt_fpexp};
      for(int i = 0; i < `ISSUE_LANE; i++) begin
        if(rvs_if.insts_valid_rvs2cq[i] && rvs_if.insts_ready_cq2rvs[i]) begin
          if(have_cur) rvs_transaction::zvt_arch_flags[cur_pc] = acc;
          acc = '0;
`ifdef TB_SUPPORT
          cur_pc = rvs_if.insts_rvs2cq[i].inst_pc;
`else
          cur_pc = 0;
`endif
          have_cur = 1;
        end
      end
    end
  end
endtask: zvt_flag_monitor
`endif

`endif // RVS_MONITOR__SV
