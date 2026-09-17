#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pass-B driver, one independent loop per key.
#
# Why not run_B_only.sh: that script launches all keys, then `wait`s for every
# worker before starting the next cycle. A single key stuck in a 900s ellmer
# backoff therefore holds the whole cycle open while every other key sits idle
# with budget quietly trickling back into it -- observed cost was 78 minutes for
# 11 batches. Here each key owns a loop: when its worker exits (budget gone, or
# finished), that key alone sleeps briefly and tries again. No key waits on
# another, so recovered budget is spent within ~RETRY seconds of appearing.
#
# Each loop stops on its own once B reaches 625/625.
#
# Usage: bash R/run_B_keys.sh
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R"
CACHE=data/cache/qwen_qwen3_8-27b
RETRY=90                       # seconds a key waits after its worker exits
cached() { ls $CACHE/*.rds 2>/dev/null | wc -l; }
log() { echo "[$(date '+%a %H:%M:%S')] $*" >> logs_B_keys.txt; }

log "=== per-key B driver starting at $(cached)/625 ==="

for k in 1 2 3 4 5 6; do
  (
    while [ "$(cached)" -lt 625 ]; do
      Rscript R/04_llm_annotate.R B 900 NA 1 1 medium "$k" > "logs_passB$k.txt" 2>&1
      n=$(cached)
      log "key$k worker exited; B=$n/625"
      [ "$n" -ge 625 ] && break
      sleep $RETRY
    done
    log "key$k loop done"
  ) &
  sleep 1
done

wait
log "=== all key loops finished at $(cached)/625 ==="
