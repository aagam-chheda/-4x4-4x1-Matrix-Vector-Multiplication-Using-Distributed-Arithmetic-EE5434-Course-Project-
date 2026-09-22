@echo off
REM Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
REM multiplier regression -- native Windows equivalent of run_vivado.sh,
REM for a Vivado install on Windows (not inside WSL).
REM
REM Run this from a shell that already has xsc/xvlog/xelab/xsim on PATH,
REM e.g. an ordinary Command Prompt after running
REM   call C:\Xilinx\Vivado\<version>\settings64.bat
REM (adjust the install path/version to your machine). Note: Vivado's
REM "<version> Tcl Shell" Start Menu shortcut opens Vivado's own Tcl
REM console (a "Vivado%" prompt), NOT a plain shell with these as
REM standalone commands -- use a plain Command Prompt with settings64.bat
REM sourced instead.
REM
REM Runs directly from this directory (does not cd into a work
REM subdirectory first): filelist.f's paths (../../rtl/..., ../../tb/...)
REM are relative to sim\vivado\, and Xilinx's xvlog resolves -f file
REM contents relative to the *invocation* directory, not relative to the
REM -f file's own location -- an earlier version of this script cd'd into
REM a work subdirectory first, which broke that resolution one level
REM short (confirmed against a real Vivado 2024.2 run: xsc succeeded,
REM Vivado's bundled MinGW gcc built golden_model.c fine, but xvlog then
REM failed with "Can not find file: ../../rtl/da_matvec_mult.sv"). Xilinx's
REM own build artifacts (xsim.dir\, .Xil\, golden_model.a, etc.) are left
REM in this directory and gitignored, rather than relocated.

setlocal enabledelayedexpansion
cd /d "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir
if exist .Xil rmdir /s /q .Xil
del /q golden_model.a golden_model.so *.jou *.log *.wdb *.pb >nul 2>&1

echo == Compiling DPI-C golden model with xsc ==
call xsc ..\..\dpi\golden_model.c -o golden_model
if errorlevel 1 goto :fail

echo == Compiling SystemVerilog sources with xvlog ==
call xvlog --sv -i ..\..\common -f filelist.f
if errorlevel 1 goto :fail

echo == Elaborating with xelab (linking DPI-C shared lib) ==
call xelab da_matvec_tb -sv_lib golden_model -s da_matvec_tb_sim
if errorlevel 1 goto :fail

echo == Running with xsim (batch mode) ==
call xsim da_matvec_tb_sim -R %*
if errorlevel 1 goto :fail

exit /b 0

:fail
echo.
echo Build/elaborate/run failed -- see the xsc/xvlog/xelab/xsim output above.
exit /b 1
