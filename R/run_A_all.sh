#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pass A across every key, one independent loop each, until 625/625.
#
# Designed to be left running overnight:
#   - each key runs its own loop, so no key waits on another;
#   - a key with no budget backs off 7 minutes and retries, so it picks up
#     whatever the rolling 24-hour window releases;
#   - every completed request is cached, so nothing is ever redone;
#   - stale claims from previously killed workers are cleared at startup, which
#     otherwise lock those batches out for the 45-minute claim TTL.
#
# Pacing is derived in 04_llm_annotate.R from the token reservation
# (prompt + max_tokens) against the 8,000-per-minute per-key bucket, so each key
# runs as fast as it is individually allowed and no faster.
#
# Usage: bash R/run_A_all.sh
# ---------------------------------------------------------------------------
cd "D:/GERMANY/NOTES/R" || exit 1
NKEYS=$(grep -c '[^[:space:]]' groq_keys.txt)
CACHE=data/cache/openai_gpt-oss-120b

# Replace anything already running for pass A; leave other passes alone.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='Rscript.exe'\" | Where-Object { \$_.CommandLine -match 'annotate.R\" \"A\"|annotate.R A ' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>/dev/null
sleep 2
rm -rf "$CACHE/_claims"

echo "pass A at $(ls "$CACHE"/*.rds 2>/dev/null | wc -l)/625 -- one loop per key on $NKEYS keys"
for k in $(seq 1 "$NKEYS"); do
  nohup bash R/run_A_key.sh "$k" > /dev/null 2>&1 &
  sleep 1
done
echo "launched $NKEYS independent key loops; they stop themselves at 625/625"
echo "progress:  bash R/status.sh"
