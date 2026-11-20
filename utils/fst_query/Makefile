# Build fst_query without Bazel.
#
#   make              build build/fst_query
#   make clean
#   make check-deps   report what is missing
#
# Expects the `hdl` nix devShell (nix develop .#hdl) for `verilator` and the C++
# toolchain, plus pkg-config and these libraries on the build environment's
# search paths: abseil-cpp, re2, zlib, lz4. (They are not in the devShell by
# default; see the README.)
#
# fst_query only needs Verilator's *headers* (fstcpp/fstcpp*.h are header-only
# for what it uses), so no Verilator runtime sources are compiled.
#
# fst_query_test is not built here: it needs gtest plus the Bazel-built
# tests/cocotb:math.elf and tests/verilator_sim:core_mini_axi_sim.

CXX        ?= c++
CXXFLAGS   ?= -O2 -g
VERILATOR  ?= verilator
PKG_CONFIG ?= pkg-config

# This directory, and the repo root (sources include "utils/fst_query/fst_query.h").
SRC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT  := $(abspath $(SRC_DIR)/../..)
BUILD_DIR  ?= $(SRC_DIR)/build

# Verilator's include/ provides fstcpp/*.h.
VERILATOR_ROOT ?= $(shell $(VERILATOR) --getenv VERILATOR_ROOT 2>/dev/null)
VERILATOR_INC   := $(VERILATOR_ROOT)/include

# Same module set as the Bazel deps (flags, status, strings, re2, zlib, lz4).
PKGS := absl_flags absl_flags_parse absl_flags_usage absl_flags_config \
        absl_status absl_statusor absl_strings re2 zlib liblz4

PKG_CFLAGS := $(shell $(PKG_CONFIG) --cflags $(PKGS) 2>/dev/null)
PKG_LIBS   := $(shell $(PKG_CONFIG) --libs   $(PKGS) 2>/dev/null)

STD        := -std=c++20
INCLUDES   := -I$(REPO_ROOT) -I$(VERILATOR_INC)

SRCS := fst_query.cc main.cc
OBJS := $(SRCS:%.cc=$(BUILD_DIR)/%.o)
HDRS := $(wildcard $(SRC_DIR)/*.h)

.PHONY: all clean check-deps help
all: $(BUILD_DIR)/fst_query

$(BUILD_DIR):
	@mkdir -p $@

# Fail early, with a useful message, if the environment is incomplete.
check-deps:
	@ok=1; \
	command -v $(CXX) >/dev/null 2>&1 || { echo "missing: C++ compiler ($(CXX))"; ok=0; }; \
	command -v $(PKG_CONFIG) >/dev/null 2>&1 || { echo "missing: $(PKG_CONFIG)"; ok=0; }; \
	[ -f "$(VERILATOR_INC)/fstcpp/fstcpp.h" ] || { \
	  echo "missing: $(VERILATOR_INC)/fstcpp/fstcpp.h (is verilator on PATH? is it >= 5.04x?)"; ok=0; }; \
	for p in $(PKGS); do \
	  $(PKG_CONFIG) --exists $$p 2>/dev/null || { echo "missing pkg-config module: $$p"; ok=0; }; \
	done; \
	[ $$ok = 1 ] && echo "all dependencies found" || { echo; echo "See the header of this Makefile / README."; exit 1; }

# Run the dependency check once per build dir (its error output stays visible).
$(BUILD_DIR)/.deps_ok: | $(BUILD_DIR)
	@$(MAKE) --no-print-directory -f $(lastword $(MAKEFILE_LIST)) check-deps && touch $@

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cc $(HDRS) | $(BUILD_DIR)/.deps_ok
	$(CXX) $(STD) $(CXXFLAGS) $(INCLUDES) $(PKG_CFLAGS) -c $< -o $@

$(BUILD_DIR)/fst_query: $(OBJS)
	$(CXX) $(OBJS) -o $@ $(LDFLAGS) $(PKG_LIBS) -ldl

clean:
	rm -rf $(BUILD_DIR)

help:
	@sed -n '1,/^CXX/p' $(lastword $(MAKEFILE_LIST)) | sed '$$d'
