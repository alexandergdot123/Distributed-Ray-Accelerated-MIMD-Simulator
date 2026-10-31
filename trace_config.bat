@echo off
REM AI [MERGE 2026-10-31]: main repo now has the fork code through [160] (link-race fix, deterministic sim); same settings as the B9 runs. Previous trace_config (run 114) is in ai_tools\pre_fork_merge_20261031\
set DRAEM_CYCLES=20000000
set DRAEM_MEM_PROFILE=hbm3
set DRAEM_CYC_RING=16384
set DRAEM_STATE_HASH=50000
