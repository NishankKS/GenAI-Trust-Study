#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pass-B-only driver. Same shape as run_passes.sh, but never touches A or C, so
# B gets all five per-key token buckets to itself instead of losing the first
# window of every cycle to A. Runs until B reaches 625/625.
#
# Usage: bash R/run_B_only.sh [max_cycles]
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R"
CYCLES=${1:-200}
CACHE=data/cache/qwen_qwen3_8-27b
log() { echo "[$(date '+%a %H:%M:%S')] $*"; }
cached() { ls $CACHE/*.rds 2>/dev/null | wc -l; }

for c in $(seq 1 "$CYCLES"); do
  n=$(cached)
  if [ "$n" -ge 625 ]; then log "pass B COMPLETE ($n/625)"; break; fi
  if ! python R/budget_check.py "qwen/qwen3.8-27b" > /tmp/budget_B.txt 2>&1; then
    log "cycle $c: no budget on any key ($n/625); re-checking in 10 min"
    sleep 600; continue
  fi
  KEYS_OK=$(cat .usable_keys 2>/dev/null); [ -z "$KEYS_OK" ] && KEYS_OK="1 2 3 4 5"
  log "cycle $c: B at $n/625, starting on keys: $KEYS_OK"
  for k in $KEYS_OK; do
    nohup Rscript R/04_llm_annotate.R B 900 NA 1 1 medium "$k" \
      > "logs_passB$k.txt" 2>&1 &
    sleep 1
  done
  wait
  after=$(cached)
  log "cycle $c: B $n -> $after / 625"
  if [ "$after" -ge 625 ]; then log "pass B COMPLETE (625/625)"; break; fi
  # Rolling 24h budget trickles back; poll rather than wait for a reset.
  sleep 600
done
log "B driver finished at $(cached)/625"
