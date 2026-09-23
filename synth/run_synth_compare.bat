@echo off
REM Synthesize both variants in Vivado and print a side-by-side summary.
REM Run from a Command Prompt with Vivado on PATH:
REM   call C:\Xilinx\Vivado\2024.2\settings64.bat
REM Usage: run_synth_compare.bat [part] [period_ns] [impl 1|0]
setlocal
cd /d "%~dp0"
set PART=%1
if "%PART%"=="" set PART=xc7a35tcpg236-1
set PERIOD=%2
if "%PERIOD%"=="" set PERIOD=3.0
set IMPL=%3
if "%IMPL%"=="" set IMPL=1

call vivado -mode batch -nojournal -nolog -source synth_compare.tcl -tclargs da_matvec_mult %PART% %PERIOD% %IMPL% > reports_da_matvec_mult.log 2>&1
call vivado -mode batch -nojournal -nolog -source synth_compare.tcl -tclargs da_matvec_mult_obc %PART% %PERIOD% %IMPL% > reports_da_matvec_mult_obc.log 2>&1

echo.
echo === Summary ===
findstr /C:"SUMMARY" /C:"ERROR" reports_da_matvec_mult.log reports_da_matvec_mult_obc.log
