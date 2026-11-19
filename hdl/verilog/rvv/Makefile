SHELL := /usr/bin/env
.SHELLFLAGS := bash -c

ifneq ($(shell command -v vcs 2>/dev/null || true),)

Aligner: Aligner.sv
	@vcs -full64 -sverilog Aligner.sv -o Aligner

Aligner_tb: Aligner_tb.sv Aligner.sv
	@vcs -full64 -sverilog Aligner.sv Aligner_tb.sv -o Aligner_tb

MultiFifo: MultiFifo.sv
	@vcs -full64 -sverilog MultiFifo.sv -o MultiFifo

MultiFifo_tb: MultiFifo_tb.sv MultiFifo.sv
	@vcs -full64 -sverilog MultiFifo.sv MultiFifo_tb.sv -o MultiFifo_tb

.PHONY : clean

clean:
	@rm -f Aligner Aligner_tb MultiFifo MultiFifo_tb

else
# Verilator flow for the RVV backend and its UVM testbench (no Bazel/VCS).
#
#   make lint                      lint the RTL only (no UVM needed)
#   make build UVM_HOME=<path>     build the testbench simulator
#   make sim   UVM_HOME=<path> test=<uvm_test> [seed=N]
#   make filelists                 only generate the filelists
#   make show / make clean
#
# The testbench is UVM-based. Verilator does not ship UVM, so building and
# running it needs a UVM source tree (UVM_HOME, containing src/uvm_pkg.sv)
# and a Verilator new enough to elaborate it (5.x with --timing). `lint`
# does not need either.
#
# Run from hdl/verilog/rvv. Output goes to build/<scfg>/.

# ------------------------------------------------------------------
# Options
# ------------------------------------------------------------------
VERILATOR ?= verilator
scfg      ?= rvv_backend
test      ?= alu_smoke_test
VLEN_DEFINE ?= VLEN_128
# Mask-result tail policy the model follows (RVV spec 3.4.3), per instruction class:
#   undisturbed | all_ones | calculated
# MASK_TAIL sets every class at once; MASK_TAIL_LOGIC (vmand...), MASK_TAIL_SET (vmsbf/vmsif/vmsof),
# MASK_TAIL_CMP (vms* compares) and MASK_TAIL_CARRY (vmadc/vmsbc) override one class.
# Defaults match the DUT: mask-logical calculates its tail, the other classes leave it undisturbed.
MASK_TAIL       ?=
MASK_TAIL_LOGIC ?= $(or $(MASK_TAIL),calculated)
MASK_TAIL_SET   ?= $(or $(MASK_TAIL),undisturbed)
MASK_TAIL_CMP   ?= $(or $(MASK_TAIL),undisturbed)
MASK_TAIL_CARRY ?= $(or $(MASK_TAIL),undisturbed)
MASK_TAIL_TAG   := $(MASK_TAIL_LOGIC)-$(MASK_TAIL_SET)-$(MASK_TAIL_CMP)-$(MASK_TAIL_CARRY)
# Fault-only-first behaviour the model follows where the RVV spec leaves it open (see
# fof_policy_pkg in sve/rvv_backend_tb/include/inst_description.svh). Defaults match the DUT.
#   FOF_POST_FAULT: active elements after the faulting one, up to the original vl:
#                   not_updated | loaded
#   FOF_SEGMENT:    a fault inside a segment of a segment load: whole | partial
FOF_POST_FAULT  ?= not_updated
FOF_SEGMENT     ?= whole
# Zvt tile tail policy the model follows (ZVT=1 only). The tile tails are agnostic, so each element may be
# left undisturbed or overwritten with all 1s; the model follows one, per instruction class:
#   undisturbed | all_ones
# TILE_TAIL sets every class at once; TILE_TAIL_MM (vtmmu/vtmms/vtfmm: mtd outside tm x tn),
# TILE_TAIL_ZERO (vtzero: mtd outside tm x tn), TILE_TAIL_MV (vtmv.t.v: tile subset elements past
# min(vl, ETE)) and TILE_TAIL_LD (vtle: likewise) override one class. See include/rvv_zvt_model.svh.
TILE_TAIL       ?=
TILE_TAIL_MM    ?= $(or $(TILE_TAIL),undisturbed)
TILE_TAIL_ZERO  ?= $(or $(TILE_TAIL),undisturbed)
TILE_TAIL_MV    ?= $(or $(TILE_TAIL),undisturbed)
TILE_TAIL_LD    ?= $(or $(TILE_TAIL),undisturbed)
TILE_TAIL_TAG   := $(TILE_TAIL_MM)-$(TILE_TAIL_ZERO)-$(TILE_TAIL_MV)-$(TILE_TAIL_LD)
# FP=1 builds the Zve32f floating point backend (ZVE32F_ON). The FP units wrap CVFPU (fpnew); its RTL,
# and that of common_cells and fpu_div_sqrt_mvp, is fetched with Bender (see Bender.yml, Bender.local
# and Bender.lock). Needs `bender` on PATH, or BENDER=<path>, and network access on the first run.
# ZVT=1 additionally builds the Zvt matrix extension (ZVT_ON, design/Zvt/). It needs the FP units, so it
# implies FP=1. TE (the tile edge) is VLEN/8.
ZVT        ?= 0
ifeq ($(ZVT),1)
  FP := 1
endif
FP         ?= 0
BENDER     ?= bender
UVM_HOME  ?=
UVM_VERBOSITY ?= UVM_LOW
timeout   ?= 1000000000ns
max_error ?= 1
JOBS      ?= $(shell nproc)
VERILATOR_FLAGS ?=
PLUS_ARGS ?=

# Verilator is 2-state: uninitialised variables get 0 or random bits, never X.
# The testbench relies on VCS's X (e.g. `if(rvs_if.vcsr_ready)` before the first
# assignment is false in VCS). Default to zero-init; RAND_RESET=2 randomises it.
RAND_RESET ?= 0

ifdef seed
  SEED_ARG = +verilator+seed+$(seed) +verilator+rand+reset+$(RAND_RESET)
else
  SEED_ARG = +verilator+seed+1 +verilator+rand+reset+$(RAND_RESET)
endif

# ------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------
RVV_ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DESIGN_PATH := $(RVV_ROOT)/design
STD_PATH    := $(RVV_ROOT)/common
RTL_INC_DIR := $(RVV_ROOT)/inc
TB_PATH     := $(RVV_ROOT)/sve/rvv_backend_tb
BUILD_PATH  := $(RVV_ROOT)/build/$(scfg)$(if $(filter-out VLEN_128,$(VLEN_DEFINE)),_vlen$(VLEN_DEFINE:VLEN_%=%))$(if $(filter 1,$(FP)),_fp)$(if $(filter 1,$(ZVT)),_zvt)$(if $(filter 1,$(TRACE)),_trace)$(if $(filter-out calculated-undisturbed-undisturbed-undisturbed,$(MASK_TAIL_TAG)),_tail_$(MASK_TAIL_TAG))$(if $(filter-out not_updated-whole,$(FOF_POST_FAULT)-$(FOF_SEGMENT)),_fof_$(FOF_POST_FAULT)-$(FOF_SEGMENT))$(if $(filter-out undisturbed-undisturbed-undisturbed-undisturbed,$(TILE_TAIL_TAG)),_ttail_$(TILE_TAIL_TAG))
TB_TOP      := rvv_backend_top

# ------------------------------------------------------------------
# Sources
# ------------------------------------------------------------------
RTL_UNUSED := $(DESIGN_PATH)/Aligner.sv \
              $(DESIGN_PATH)/Aligner_tb.sv \
              $(DESIGN_PATH)/MultiFifo.sv \
              $(DESIGN_PATH)/MultiFifo_tb.sv \
              $(DESIGN_PATH)/RvvBackend.sv \
              $(STD_PATH)/fifo_flopped_2w2r.sv \
              $(STD_PATH)/fifo_flopped_4w2r.sv \
              $(STD_PATH)/openFifo8_flopped_2w2r.sv \
              $(STD_PATH)/openFifo4_flopped_ptr.sv

RTL_FILES := $(filter-out $(RTL_UNUSED),$(sort $(wildcard $(DESIGN_PATH)/rvv_backend*.sv)) \
                                         $(sort $(wildcard $(STD_PATH)/*.sv)))
ifeq ($(ZVT),1)
  # zvt_acc.sv is stale: nothing instantiates it and it uses the undefined NUM_ACC
  RTL_FILES += $(filter-out $(DESIGN_PATH)/Zvt/zvt_acc.sv,$(sort $(wildcard $(DESIGN_PATH)/Zvt/*.sv)))
endif
TB_FILES  := $(sort $(wildcard $(TB_PATH)/hdl/*.sv))

RTL_INCDIRS := $(RTL_INC_DIR)

# Third-party RTL (FP=1 only), all through Bender (see Bender.yml):
#  - CVFPU is vendored into .vendor/cvfpu and patched with third_party/cvfpu/*.patch (the patches the
#    Bazel build applies); redone when the manifest or a patch changes.
#  - Bender then checks the remaining dependencies out into .bender/ and writes a file list (include
#    directories, defines and sources in dependency order) that rtl.f pulls in ahead of the backend
#    sources. Regenerated when the manifest, the overrides or the lock file change.
#  - Patch 0002 removes the `include of the common_cells macro headers from cvfpu, so rtl.f lists
#    assertions.svh and registers.svh itself, ahead of the Bender list.
BENDER_FLIST     := $(BUILD_PATH)/bender.f
BENDER_VENDORED  := $(RVV_ROOT)/.vendor/cvfpu/Bender.yml
CVFPU_PATCHES    := $(wildcard $(RVV_ROOT)/../../../third_party/cvfpu/*.patch)
TB_INCDIRS  := $(TB_PATH)/include $(TB_PATH)/src $(TB_PATH)/env \
               $(TB_PATH)/tests $(TB_PATH)/hdl

# ------------------------------------------------------------------
# Configurations (mirrors sve/rvv_backend_tb/Makefile)
# ------------------------------------------------------------------
# SVA (ASSERT_ON) uses `strong`, which Verilator does not support; opt in with ASSERT=1
COMMON_DEFINES := TB_SUPPORT RVV_CONFIG_SVH $(if $(ASSERT),ASSERT_ON) PRECISE_RVVTRAP $(if $(filter 1,$(FP)),ZVE32F_ON) $(if $(filter 1,$(ZVT)),ZVT_ON)
ifeq ($(scfg),rvv_backend)
  RTL_DEFINES := $(COMMON_DEFINES) ISSUE_3_READ_PORT_6
else ifeq ($(scfg),rvv_backend_i3rp6)
  RTL_DEFINES := $(COMMON_DEFINES) ISSUE_3_READ_PORT_6
else ifeq ($(scfg),rvv_backend_i2rp4)
  RTL_DEFINES := $(COMMON_DEFINES) ISSUE_2_READ_PORT_4
else ifeq ($(scfg),rvv_backend_i2rp6)
  RTL_DEFINES := $(COMMON_DEFINES) ISSUE_2_READ_PORT_6
else ifeq ($(scfg),rvv_backend_bringup)
  RTL_DEFINES := TB_BRINGUP TB_SUPPORT $(if $(ASSERT),ASSERT_ON)
  RTL_FILES   := $(DESIGN_PATH)/rvv_backend.sv
else
  $(error Unknown scfg '$(scfg)')
endif
$(foreach v,MASK_TAIL_LOGIC MASK_TAIL_SET MASK_TAIL_CMP MASK_TAIL_CARRY,$(if $(filter $($(v)),undisturbed all_ones calculated),,$(error $(v) must be one of undisturbed, all_ones or calculated, got '$($(v))')))
# Policy names map to the mask_tail_policy_e values used by the testbench: 0, 1, 2.
mask_tail_num = $(if $(filter $(1),undisturbed),0,$(if $(filter $(1),all_ones),1,2))
MASK_TAIL_DEFINES := RVV_TB_MASK_TAIL_LOGIC=$(call mask_tail_num,$(MASK_TAIL_LOGIC)) \
                     RVV_TB_MASK_TAIL_SET=$(call mask_tail_num,$(MASK_TAIL_SET)) \
                     RVV_TB_MASK_TAIL_CMP=$(call mask_tail_num,$(MASK_TAIL_CMP)) \
                     RVV_TB_MASK_TAIL_CARRY=$(call mask_tail_num,$(MASK_TAIL_CARRY))
$(if $(filter $(FOF_POST_FAULT),not_updated loaded),,$(error FOF_POST_FAULT must be not_updated or loaded, got '$(FOF_POST_FAULT)'))
$(if $(filter $(FOF_SEGMENT),whole partial),,$(error FOF_SEGMENT must be whole or partial, got '$(FOF_SEGMENT)'))
FOF_DEFINES := RVV_TB_FOF_POST_FAULT=$(if $(filter $(FOF_POST_FAULT),loaded),1,0) \
               RVV_TB_FOF_SEGMENT=$(if $(filter $(FOF_SEGMENT),partial),1,0)
$(foreach v,TILE_TAIL_MM TILE_TAIL_ZERO TILE_TAIL_MV TILE_TAIL_LD,$(if $(filter $($(v)),undisturbed all_ones),,$(error $(v) must be undisturbed or all_ones, got '$($(v))')))
# Policy names map to the tile_tail_policy_e values used by the testbench: 0, 1.
tile_tail_num = $(if $(filter $(1),all_ones),1,0)
TILE_TAIL_DEFINES := RVV_TB_TILE_TAIL_MM=$(call tile_tail_num,$(TILE_TAIL_MM)) \
                     RVV_TB_TILE_TAIL_ZERO=$(call tile_tail_num,$(TILE_TAIL_ZERO)) \
                     RVV_TB_TILE_TAIL_MV=$(call tile_tail_num,$(TILE_TAIL_MV)) \
                     RVV_TB_TILE_TAIL_LD=$(call tile_tail_num,$(TILE_TAIL_LD))
DEFINES := $(RTL_DEFINES) $(VLEN_DEFINE) $(MASK_TAIL_DEFINES) $(FOF_DEFINES) $(TILE_TAIL_DEFINES)

# ------------------------------------------------------------------
# Verilator invocation
# ------------------------------------------------------------------
UVM_INC   := $(if $(UVM_HOME),+incdir+$(UVM_HOME)/src)
UVM_FILES := $(if $(UVM_HOME),$(UVM_HOME)/src/uvm_pkg.sv)

WARN_FLAGS := -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-WIDTH \
              -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE

# Testbench-only: the UVM testbench relies on VCS leniency. ENUMVALUE is the
# implicit int/bit -> enum assignment (IEEE 6.19.3); COVERIGN is Verilator
# skipping covergroup option.comment. Kept out of `lint` so RTL stays strict.
TB_WARN_FLAGS := -Wno-ENUMVALUE -Wno-COVERIGN

# TRACE=1: build with an FST waveform of the DUT (waves.fst, written to the run
# directory). Uses its own build dir (build/<scfg>_trace) so the normal build is
# untouched. Inspect with //utils/fst_query (see utils/fst_query/README.md).
ifeq ($(TRACE),1)
  TRACE_FLAGS := --trace-fst --trace-structs +define+TRACE_ON
endif

VFLAGS = --sv --timing -j $(JOBS) $(WARN_FLAGS) $(TB_WARN_FLAGS) \
         --x-assign unique --x-initial unique \
         --Mdir $(BUILD_PATH)/obj_dir --top-module $(TB_TOP) \
         $(VERILATOR_FLAGS)

# ------------------------------------------------------------------
# Targets
# ------------------------------------------------------------------
.PHONY: all build sim lint filelists show clean help
all: build

filelists: $(BUILD_PATH)/rtl.f $(BUILD_PATH)/tb.f $(BUILD_PATH)/lint.f

$(BUILD_PATH):
	@mkdir -p $@

.PHONY: deps
deps: $(BENDER_FLIST)

$(BENDER_VENDORED): $(RVV_ROOT)/Bender.yml $(CVFPU_PATCHES)
	@command -v $(BENDER) >/dev/null 2>&1 || { echo "error: FP=1 needs bender (https://github.com/pulp-platform/bender); put it on PATH or set BENDER=<path>"; exit 1; }
	@# `vendor init` loads the manifest, which already names this (not yet existing) path dependency
	mkdir -p $(dir $@)
	cd $(RVV_ROOT) && $(BENDER) vendor init
	@# Without a lock file `vendor init` resolves while the vendored copy is still empty, so the lock misses
	@# CVFPU's own dependencies; resolve again now that its manifest exists.
	@cd $(RVV_ROOT) && grep -q '^  common_cells:' Bender.lock 2>/dev/null || $(BENDER) update

$(BENDER_FLIST): $(RVV_ROOT)/Bender.yml $(RVV_ROOT)/Bender.local $(wildcard $(RVV_ROOT)/Bender.lock) $(BENDER_VENDORED) | $(BUILD_PATH)
	cd $(RVV_ROOT) && $(BENDER) checkout
	cd $(RVV_ROOT) && $(BENDER) script flist-plus -e tech_cells_generic -e common_verification > $@

# Regenerate whenever the Makefile, scfg or source set changes.
$(BUILD_PATH)/rtl.f: Makefile $(if $(filter 1,$(FP)),$(BENDER_FLIST)) | $(BUILD_PATH) $(RTL_FILES) $(foreach incdir,$(RTL_INCDIRS),$(wildcard $(incdir)/*))
	@echo "generating $@"
	@{ for i in $(RTL_INCDIRS); do echo "+incdir+$$i"; done; \
	   for d in $(DEFINES); do echo "+define+$$d"; done; \
	   $(if $(filter 1,$(FP)),cc=$$(cd $(RVV_ROOT) && $(BENDER) path common_cells); \
	     echo "$$cc/include/common_cells/assertions.svh"; echo "$$cc/include/common_cells/registers.svh"; \
	     echo "-f $(BENDER_FLIST)";) \
	   for f in $(RTL_FILES); do echo "$$f"; done; } > $@

$(BUILD_PATH)/tb.f: Makefile | $(BUILD_PATH) $(TB_FILES) $(foreach incdir,$(TB_INCDIRS),$(wildcard $(incdir)/*))
	@echo "generating $@"
	@{ for i in $(TB_INCDIRS); do echo "+incdir+$$i"; done; \
	   for f in $(TB_FILES); do echo "$$f"; done; } > $@

# RTL-only lint: the backend top, without the testbench
$(BUILD_PATH)/lint.f: $(BUILD_PATH)/rtl.f
	@echo "generating $@"
	@cp $< $@

# These depend on the file set, not only the Makefile.
$(BUILD_PATH)/rtl.f $(BUILD_PATH)/tb.f: $(RTL_FILES) $(TB_FILES) $(wildcard $(RTL_INC_DIR)/*.svh) \
  $(foreach incdir,$(TB_INCDIRS),$(wildcard $(incdir)/*))

lint: $(BUILD_PATH)/lint.f
	$(VERILATOR) --lint-only --sv --timing $(WARN_FLAGS) -Wall \
	  --top-module rvv_backend -f $(BUILD_PATH)/lint.f $(VERILATOR_FLAGS)

UVM_DPI_SRCS  := $(UVM_HOME)/src/dpi/uvm_dpi.cc
UVM_DPI_FLAGS := --vpi -CFLAGS -I$(UVM_HOME)/src/dpi

# The testbench is mostly `included from its include directories, so every source there is a
# dependency of the simulator, not only the files named in the file lists.
TB_DEPS := $(foreach d,$(TB_INCDIRS),$(wildcard $(d)/*.sv $(d)/*.svh $(d)/*.incl))

$(BUILD_PATH)/obj_dir/V$(TB_TOP): $(BUILD_PATH)/rtl.f $(BUILD_PATH)/tb.f $(TB_DEPS) $(RTL_FILES) $(wildcard $(RTL_INC_DIR)/*.svh)
	@test -n "$(UVM_HOME)" || { echo "error: set UVM_HOME to a UVM tree containing src/uvm_pkg.sv"; exit 1; }
	@# uvm_pkg.sv must come first so the UVM macros are defined for the testbench
	@# (VCS gets this implicitly from -ntb_opts uvm).
	set -o pipefail; $(VERILATOR) --binary $(VFLAGS) $(UVM_DPI_FLAGS) $(TRACE_FLAGS) --error-limit 200 \
	  $(UVM_INC) $(UVM_FILES) \
	  -f $(BUILD_PATH)/rtl.f -f $(BUILD_PATH)/tb.f $(UVM_DPI_SRCS) 2>&1 | tee $(BUILD_PATH)/verilator.log

build: $(BUILD_PATH)/obj_dir/V$(TB_TOP)

SIM_PATH = $(subst build,outfiles,$(BUILD_PATH))/$(test)$(if $(seed),.$(seed))

sim: build
	@mkdir -p $(SIM_PATH)
	cd $(SIM_PATH) && $(BUILD_PATH)/obj_dir/V$(TB_TOP) \
	  $(SEED_ARG) $(PLUS_ARGS) \
	  +UVM_TESTNAME=$(test) +UVM_VERBOSITY=$(UVM_VERBOSITY) \
	  +UVM_MAX_QUIT_COUNT=$(max_error),NO +UVM_TIMEOUT=$(timeout) \
	  2>&1 | tee $(SIM_PATH)/test.log
	@echo "Test log: $(SIM_PATH)/test.log"

show:
	@echo "scfg:     $(scfg)"
	@echo "defines:  $(DEFINES)"
	@echo "RTL files: $(words $(RTL_FILES))"
	@echo "TB files:  $(words $(TB_FILES))"
	@echo "build:    $(BUILD_PATH)"

clean:
	rm -rf $(RVV_ROOT)/build $(RVV_ROOT)/outfiles

help:
	@sed -n '/^else/,/^SHELL/{//!p;/^SHELL/q}' $(firstword $(MAKEFILE_LIST)) | sed '$$d'

endif
