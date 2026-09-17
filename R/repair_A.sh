#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fill pass A's gaps, one independent loop per key.
#
# Rather than re-running 209 truncated batches whole, this re-requests only the
# comments that have no annotation -- 798 of them -- re-batched into ~100 full
# groups of 8. Roughly half the calls for the same result.
#
# Nothing is deleted. Repair batches group different ids, so they get their own
# cache keys and sit alongside the originals; the assemble step unions every
# cached batch and dedupes by id, so the gaps simply fill in.
#
# Safe to run at full speed: 04_llm_annotate.R now detects a short batch and
# retries it at double the completion ceiling before caching, so the truncation
# that created these gaps cannot recur silently.
#
# Usage: bash R/repair_A.sh
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R" || exit 1
CACHE=data/cache/openai_gpt-oss-120b
LOG=logs_A_repair.txt
log() { echo "[$(date '+%a %H:%M:%S')] $*" >> "$LOG"; }

# Recompute the gap list, so a re-run only ever chases what is still missing.
Rscript R/find_missing.R A
MISS=$(( $(wc -l < data/derived/missing_ids_A.csv) - 1 ))
if [ "$MISS" -le 0 ]; then echo "nothing missing -- pass A is complete"; exit 0; fi
echo "repairing $MISS missing annotations (~$(( (MISS + 7) / 8 )) calls) on 6 keys"

# Replace any running pass-A worker and release its claim locks.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='Rscript.exe'\" | Where-Object { \$_.CommandLine -match 'annotate.R\" \"A\"|annotate.R A ' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>/dev/null
sleep 2
rm -rf "$CACHE/_claims"

log "=== repair starting: $MISS missing ==="
for k in 1 2 3 4 5 6; do
  (
    while :; do
      # args: pass max_req n_items shard n_shards effort key rate max_tok repair
      # Rate arg is now only the SEED: the worker adapts per key from there.
      Rscript R/04_llm_annotate.R A 900 NA 1 1 medium "$k" 1.49 3000 repair \
        > "logs_repairA$k.txt" 2>&1
      Rscript R/find_missing.R A > /dev/null 2>&1
      left=$(( $(wc -l < data/derived/missing_ids_A.csv) - 1 ))
      log "key$k window ended; $left annotations still missing"
      [ "$left" -le 0 ] && break
      sleep 90
    done
    log "key$k done"
  ) &
  sleep 1
done
wait
log "=== repair complete ==="
