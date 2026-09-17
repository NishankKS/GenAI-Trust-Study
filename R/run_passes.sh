#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Annotation scheduler.
#
# Why sequential: Groq's per-minute token bucket (8,000) is per KEY and shared
# across models, while the daily token budget (200,000) is per key PER MODEL.
# Running all three passes at once therefore puts 3 requests/30s onto a bucket
# that sustains ~2 requests/minute, and the largest requests -- pass A's -- lose
# every collision and starve. One pass at a time, spread over all four keys,
# saturates the per-minute bucket without colliding, and each pass still draws
# on its own daily budget.
#
# Each pass runs until it either finishes or exhausts its daily tokens, then the
# next begins. Order is A first: it is the critical path and the primary
# annotator. All work is cached per request, so a pass resumes exactly where it
# stopped on the next run.
#
# Usage: bash R/run_passes.sh [cycles]
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R"
CYCLES=${1:-1}
log() { echo "[$(date '+%a %H:%M:%S')] $*"; }

cached() {
  case "$1" in
    A) ls data/cache/openai_gpt-oss-120b/*.rds          2>/dev/null | wc -l ;;
    B) ls data/cache/qwen_qwen3_8-27b/*.rds             2>/dev/null | wc -l ;;
    C) ls data/cache/openai_gpt-oss-safeguard-20b/*.rds 2>/dev/null | wc -l ;;
  esac
}

model_of() {
  case "$1" in
    A) echo "openai/gpt-oss-120b" ;;
    B) echo "qwen/qwen3.8-27b" ;;
    C) echo "openai/gpt-oss-safeguard-20b" ;;
  esac
}

run_pass() {
  local P=$1 before after
  before=$(cached "$P")
  if [ "$before" -ge 625 ]; then log "pass $P already complete (625/625)"; return; fi
  # Preflight: the daily budget is a rolling window, and a pass launched with no
  # budget blocks for 10-20 minutes inside ellmer's retry loop instead of
  # yielding the time to a pass that can use it.
  if ! python R/budget_check.py "$(model_of "$P")" > /tmp/budget_$P.txt 2>&1; then
    log "pass $P skipped -- no daily budget on any key"
    sed 's/^/        /' /tmp/budget_$P.txt
    return
  fi
  local KEYS_OK
  KEYS_OK=$(cat .usable_keys 2>/dev/null)
  [ -z "$KEYS_OK" ] && KEYS_OK="1 2 3 4"
  log "pass $P starting at $before/625 on keys: $KEYS_OK"
  for k in $KEYS_OK; do
    nohup Rscript R/04_llm_annotate.R "$P" 900 NA 1 1 medium "$k" \
      > "logs_pass$P$k.txt" 2>&1 &
    sleep 1
  done
  wait                                   # workers exit on completion or TPD
  after=$(cached "$P")
  log "pass $P finished this window: $before -> $after / 625"
}

for c in $(seq 1 "$CYCLES"); do
  log "=== cycle $c of $CYCLES ==="
  for P in A B C; do run_pass "$P"; done
  log "cycle $c done: A=$(cached A) B=$(cached B) C=$(cached C)"
  if [ "$c" -lt "$CYCLES" ]; then
    # The daily budget is a ROLLING 24h window, so it does not refill in one
    # step at midnight -- it trickles back continuously as older spend ages out.
    # A short cycle drains it as it becomes available instead of waiting for a
    # reset that never happens.
    # The rolling window releases tokens continuously, and an idle-cycle check
    # is now cheap: a pass with no budget exits in seconds rather than sitting in
    # a retry backoff. So poll often -- budget that appears mid-sleep is budget
    # left unused.
    log "no budget this cycle; re-checking in 10 minutes"
    sleep 600
  fi
done
log "scheduler finished: A=$(cached A) B=$(cached B) C=$(cached C)"
