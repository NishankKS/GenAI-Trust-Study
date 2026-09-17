#!/usr/bin/env bash
# Wait for the currently running annotation workers to finish (they exit when
# the daily token budget for their model is gone), then hand control to the
# scheduler, which cycles A -> B -> C and re-checks budgets every 40 minutes.
cd "D:/GERMANY/NOTES/R"
echo "[$(date '+%a %H:%M')] waiting for the running pass-A workers to exit"
while [ "$(ps -W 2>/dev/null | grep -ci rscript)" -gt 0 ]; do sleep 60; done
echo "[$(date '+%a %H:%M')] workers done; starting scheduler"
exec bash R/run_passes.sh 60
