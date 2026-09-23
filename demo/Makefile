# Verilator build/run for the true-parameterization presentation demo.
# Self-contained: does not touch sim/verilator/ or its build artifacts,
# and does not run the verification suite.

VERILATOR   ?= verilator
TOP          = demo_tb
RTL_DIR      = ../rtl
COMMON_DIR   = ../common

SV_SRCS      = $(RTL_DIR)/da_matvec_mult.sv demo_tb.sv

# -I$(COMMON_DIR) is still needed even though every instance in this demo
# overrides A_FLAT: da_matvec_mult.sv's `include "matrix_a.inc" is inside
# that parameter's DEFAULT value expression, which is still parsed (even
# if never used) whenever the module itself is parsed.
# -I. lets demo_tb.sv's `include "demo_data.svh" resolve.
VERILATOR_FLAGS = --binary --timing -Wall -Wno-DECLFILENAME -I$(COMMON_DIR) -I.

.PHONY: all run clean

all: run

obj_dir/V$(TOP): $(SV_SRCS) demo_data.svh $(COMMON_DIR)/matrix_a.inc
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP) \
		$(SV_SRCS) -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir
