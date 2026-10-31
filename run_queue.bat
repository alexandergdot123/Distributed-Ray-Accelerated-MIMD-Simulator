@echo off
REM AI [71]: run queue. Start once (double-click). Claude starts a run by creating rust_rt_arch_sim\src\run_request.flag
REM and stops one by creating rust_rt_arch_sim\src\stop_run.flag (the simulator checks it every 10K cycles). Close this window to stop the queue.
cd /d "%~dp0"
title DRAEM run queue
:wait
if exist rust_rt_arch_sim\src\run_request.flag (
  del rust_rt_arch_sim\src\run_request.flag
  if exist rust_rt_arch_sim\src\stop_run.flag del rust_rt_arch_sim\src\stop_run.flag
  echo %DATE% %TIME% starting run
  call run_sim.bat
  cd /d "%~dp0"
  echo %DATE% %TIME% run finished, waiting for the next request
)
timeout /t 15 /nobreak >nul
goto wait
