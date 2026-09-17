#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pass-A driver, one independent loop per key.
#
# Same design as run_B_keys.sh, and for the same measured reason: run_A_only.sh
# launches every key then waits for all of them before the next window, so one
# key stuck in a ~900s ellmer backoff holds the window open while the others sit
# idle with budget trickling back. On pass B that pattern cost 78 minutes for 11
# batches; per-key loops raised the same run to ~20 batches/hour.
#
# A uses gpt-oss-120b, a different model from B's qwen, so it draws on its own
# per-key daily token budget. It shares only the per-minute bucket -- which the
# header probe shows sits ~99% idle -- so this does not need to wait for B.
#
# Each loop stops on its own once A reaches 625/625.
#
# Usage: bash R/run_A_keys.sh
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R"
CACHE=data/cache/openai_gpt-oss-120b
RETRY=90                       # seconds a key waits after its worker exits
cached() { ls $CACHE/*.rds 2>/dev/null | wc -l; }
log() { echo "[$(date '+%a %H:%M:%S')] $*" >> logs_A_keys.txt; }

log "=== per-key A driver starting at $(cached)/625 ==="

for k in 1 2 3 4 5 6; do
  (
    while [ "$(cached)" -lt 625 ]; do
      # arg 8 TARGET_RATE, arg 9 MAX_TOK. 3,000 replaces 4,800: a short batch is
      # now DETECTED and retried at double the ceiling (04_llm_annotate.R), so
      # truncation can no longer pass silently, and the leaner reservation
      # (~5,100 vs ~6,900) lifts the per-key ceiling from 1.16 to 1.57 req/min
      # and yields ~35% more requests per key per day at identical quality.
      # 2,400-token ceiling, losing the tail of every batch (item 1 returned
      # 100% of the time, item 8 only 42%, yield 5.65/8). 4,800 fits all eight
      # plus the 120b model's reasoning tokens. That raises the reservation to
      # prompt + 4,800 = ~6,855 against the 8,000/min per-key bucket, so the
      # pace must come down from 1.65 to 1.1 req/min or the requests collide
      # with each other on TPM.
      Rscript R/04_llm_annotate.R A 900 NA 1 1 medium "$k" 1.49 3000 \
        > "logs_passA$k.txt" 2>&1
      n=$(cached)
      log "key$k worker exited; A=$n/625"
      [ "$n" -ge 625 ] && break
      sleep $RETRY
    done
    log "key$k loop done"
  ) &
  sleep 1
done

wait
log "=== all key loops finished at $(cached)/625 ==="
