#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pass A only.
#
# Pass B is being run from a separate terminal, so this supervisor must never
# launch B or C -- two workers on the same pass would duplicate requests and
# collide on the per-key token bucket. It therefore drives 04_llm_annotate.R
# with the literal argument "A" and nothing else, and it kills only processes it
# started itself.
#
# A and B use DIFFERENT models (gpt-oss-120b vs qwen3.8-27b), so they draw on
# separate daily token budgets and do not compete for quota. They share only the
# per-key per-minute bucket; both sides retry transient stalls rather than
# dying, so that contention costs throughput but never a run.
#
# Runs until pass A reaches 625/625.
# ---------------------------------------------------------------------------
cd "D:/GERMANY/NOTES/R" || exit 1
CACHE=data/cache/openai_gpt-oss-120b
LOG=logs_A_supervisor.txt
NKEYS=$(grep -c '[^[:space:]]' groq_keys.txt)

count() { ls "$CACHE"/*.rds 2>/dev/null | wc -l; }

while true; do
  done_n=$(count)
  echo "[$(date '+%a %H:%M')] pass A at $done_n/625" >> "$LOG"
  if [ "$done_n" -ge 625 ]; then
    echo "[$(date '+%a %H:%M')] pass A COMPLETE" >> "$LOG"
    break
  fi

  # Only launch on keys that still have daily budget for THIS model.
  if python R/budget_check.py openai/gpt-oss-120b >> "$LOG" 2>&1; then
    KEYS=$(cat .usable_keys 2>/dev/null)
    [ -z "$KEYS" ] && KEYS=$(seq 1 "$NKEYS")
    echo "[$(date '+%a %H:%M')] launching A on keys: $KEYS" >> "$LOG"
    pids=""
    for k in $KEYS; do
      nohup Rscript R/04_llm_annotate.R A 900 NA 1 1 medium "$k" \
        > "logs_passA$k.txt" 2>&1 &
      pids="$pids $!"
      sleep 1
    done
    for p in $pids; do wait "$p" 2>/dev/null; done
    echo "[$(date '+%a %H:%M')] window done: $done_n -> $(count) / 625" >> "$LOG"
  else
    echo "[$(date '+%a %H:%M')] no 120b budget; re-checking in 10 min" >> "$LOG"
    sleep 600
  fi
done
