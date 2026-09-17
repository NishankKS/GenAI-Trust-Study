#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One persistent loop for ONE key, for pass A.
#
# The previous supervisor launched a worker per funded key and then waited for
# every one of them to exit before re-checking budgets. That wasted capacity two
# ways: a key that finished early sat idle until the slowest one stopped, and a
# key that was briefly short at launch time was excluded for the whole window
# even though its rolling budget recovered minutes later.
#
# Running one independent loop per key removes both problems -- each key works
# whenever it individually has budget, and nothing waits on anything else.
#
# Usage: bash R/run_A_key.sh <key-index>
# ---------------------------------------------------------------------------
cd "D:/GERMANY/NOTES/R" || exit 1
K=${1:?key index required}
CACHE=data/cache/openai_gpt-oss-120b
LOG=logs_A_key$K.txt
count() { ls "$CACHE"/*.rds 2>/dev/null | wc -l; }

while true; do
  n=$(count)
  if [ "$n" -ge 625 ]; then
    echo "[$(date '+%a %H:%M')] key$K: pass A complete ($n/625)" >> "$LOG"
    break
  fi
  # The worker checks this key's budget itself at startup and exits at once if
  # it is gone, so there is no need to pre-filter here -- just retry the key.
  Rscript R/04_llm_annotate.R A 900 NA 1 1 medium "$K" >> "$LOG" 2>&1
  n2=$(count)
  echo "[$(date '+%a %H:%M')] key$K: window ended, pass at $n2/625" >> "$LOG"
  # If the worker returned without gaining anything, its key is dry: wait for the
  # rolling window to release more rather than hammering it.
  if [ "$n2" -le "$n" ]; then sleep 420; else sleep 20; fi
done
