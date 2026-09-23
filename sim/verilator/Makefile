# Verilator simulation flow for the DA matrix-vector multiplier.
#
# Targets:
#   make run       - build (functional, no coverage) and run the regression
#                    against the original MSB-first module
#   make run_obc   - the SAME regression against the LSB-first Offset
#                    Binary Coding variant (rtl/da_matvec_mult_obc.sv)
#   make run_equiv - lockstep equivalence testbench: original and OBC
#                    variants side by side across several matrices
#   make coverage  - build with --coverage, run, and print an annotated
#                    line/toggle/branch coverage summary
#   make clean     - remove build/coverage artifacts

VERILATOR   ?= verilator
TOP          = da_matvec_tb
RTL_DIR      = ../../rtl
TB_DIR       = ../../tb
DPI_DIR      = ../../dpi

COMMON_DIR   = ../../common
SV_SRCS      = $(RTL_DIR)/da_matvec_mult.sv $(TB_DIR)/da_matvec_tb.sv
C_SRCS       = $(DPI_DIR)/golden_model.c

VERILATOR_FLAGS = --binary --timing -Wall -Wno-DECLFILENAME -I$(COMMON_DIR)

OBC_SV_SRCS  = $(RTL_DIR)/da_matvec_mult_obc.sv $(TB_DIR)/da_matvec_tb.sv

EQUIV_TOP    = da_matvec_equiv_tb
EQUIV_SRCS   = $(RTL_DIR)/da_matvec_mult.sv $(RTL_DIR)/da_matvec_mult_obc.sv \
               $(TB_DIR)/da_matvec_equiv_tb.sv

.PHONY: all run run_obc run_equiv coverage clean

all: run

obj_dir/V$(TOP): $(SV_SRCS) $(C_SRCS) $(COMMON_DIR)/matrix_a.inc
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP) \
		$(SV_SRCS) $(C_SRCS) -o V$(TOP)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP)

obj_dir_obc/V$(TOP)_obc: $(OBC_SV_SRCS) $(C_SRCS) $(COMMON_DIR)/matrix_a.inc
	$(VERILATOR) $(VERILATOR_FLAGS) -DDUT_OBC --top-module $(TOP) \
		$(OBC_SV_SRCS) $(C_SRCS) -Mdir obj_dir_obc -o V$(TOP)_obc

run_obc: obj_dir_obc/V$(TOP)_obc
	./obj_dir_obc/V$(TOP)_obc

obj_dir_equiv/V$(EQUIV_TOP): $(EQUIV_SRCS) $(COMMON_DIR)/matrix_a.inc
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(EQUIV_TOP) \
		$(EQUIV_SRCS) -Mdir obj_dir_equiv -o V$(EQUIV_TOP)

run_equiv: obj_dir_equiv/V$(EQUIV_TOP)
	./obj_dir_equiv/V$(EQUIV_TOP)

obj_dir_cov/V$(TOP)_cov: $(SV_SRCS) $(C_SRCS) $(COMMON_DIR)/matrix_a.inc
	$(VERILATOR) $(VERILATOR_FLAGS) --coverage --top-module $(TOP) \
		$(SV_SRCS) $(C_SRCS) -Mdir obj_dir_cov -o V$(TOP)_cov

coverage: obj_dir_cov/V$(TOP)_cov
	./obj_dir_cov/V$(TOP)_cov
	verilator_coverage --annotate cov_annotate coverage.dat
	@echo "Annotated source: sim/verilator/cov_annotate/"

clean:
	rm -rf obj_dir obj_dir_obc obj_dir_equiv obj_dir_cov cov_annotate coverage.dat
