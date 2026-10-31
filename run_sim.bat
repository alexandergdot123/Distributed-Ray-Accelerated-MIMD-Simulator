@echo off
setlocal
REM AI [105]: optional per-run overrides (DRAEM_TRACE / DRAEM_TRACE_FROM / DRAEM_CORES / DRAEM_CYCLES); setlocal keeps them out of the queue window
if exist "%~dp0trace_config.bat" call "%~dp0trace_config.bat"
REM Traces core 0 (root branch) and core 6170 (branch 1749803, whose queue stayed full in run 17). Builds and runs ...
cd /d "%~dp0rust_rt_arch_sim\src"
if exist run_ai.done del run_ai.done
if "%DRAEM_CYCLES%"=="" set DRAEM_CYCLES=5000000
REM AI [60]: per-instruction tracing off by default for long runs (set DRAEM_TRACE=1 to trace the cores listed below)
if "%DRAEM_TRACE%"=="" set DRAEM_TRACE=0
REM AI [105]: cores to trace (was hard-coded 0,6170); DRAEM_TRACE_FROM = first traced cycle
if "%DRAEM_CORES%"=="" set DRAEM_CORES=0,6170
echo START %DATE% %TIME% cycles=%DRAEM_CYCLES% trace=%DRAEM_TRACE% > run_ai.log
(echo %DRAEM_CORES%& echo.) | cargo run --release >> run_ai.log 2>&1
echo EXIT CODE %ERRORLEVEL% >> run_ai.log
echo END %DATE% %TIME% >> run_ai.log
echo done > run_ai.done
