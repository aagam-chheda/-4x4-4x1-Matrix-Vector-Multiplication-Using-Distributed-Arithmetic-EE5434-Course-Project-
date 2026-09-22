@echo off
REM Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
REM multiplier regression -- native Windows equivalent of run_vivado.sh,
REM for a Vivado install on Windows (not inside WSL).
REM
REM Run this from a shell that already has xsc/xvlog/xelab/xsim on PATH:
REM either the "Vivado <version> Tcl Shell" shortcut Vivado's installer
REM creates, or an ordinary Command Prompt / PowerShell after running
REM   call C:\Xilinx\Vivado\<version>\settings64.bat
REM (adjust the install path/version to your machine).
REM
REM NOTE: this script has not been executed against a real Vivado install
REM while authoring this repo (no Vivado available in that environment) --
REM functional sign-off there was done with Verilator (see
REM sim\verilator\). See README.md's "Running in Vivado" section for the
REM points to double-check, plus one Windows-specific one: xsc on Windows
REM needs a Microsoft Visual C++ compiler (cl.exe) discoverable on PATH
REM (e.g. via a Visual Studio Build Tools install) to compile
REM golden_model.c -- this is a different requirement from Linux xsc,
REM which just needs gcc, and is the most likely first failure point here.

setlocal enabledelayedexpansion
cd /d "%~dp0"

set WORK_DIR=xsim_work
if exist "%WORK_DIR%" rmdir /s /q "%WORK_DIR%"
mkdir "%WORK_DIR%"
cd "%WORK_DIR%"

echo == Compiling DPI-C golden model with xsc ==
call xsc ..\..\..\dpi\golden_model.c -o golden_model
if errorlevel 1 goto :fail

echo == Compiling SystemVerilog sources with xvlog ==
REM -i points xvlog's `include search path at common\matrix_a.inc (the
REM single source of truth for matrix A, shared with the DPI-C golden
REM model). filelist.f itself uses forward-slash relative paths, which
REM Xilinx's Windows tools accept.
call xvlog --sv -i ..\..\..\common -f ..\filelist.f
if errorlevel 1 goto :fail

echo == Elaborating with xelab (linking DPI-C shared lib) ==
call xelab da_matvec_tb -sv_lib golden_model -s da_matvec_tb_sim
if errorlevel 1 goto :fail

echo == Running with xsim (batch mode) ==
call xsim da_matvec_tb_sim -R
if errorlevel 1 goto :fail

cd ..
exit /b 0

:fail
cd ..
echo.
echo Build/elaborate/run failed -- see the xsc/xvlog/xelab/xsim output above.
exit /b 1
