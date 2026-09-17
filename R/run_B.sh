#!/usr/bin/env bash
# Launch pass B on every key, and nothing else.
#
# Restarting picks up the current worker code; everything already fetched is
# cached per request, so a restart costs at most one in-flight call per worker.
# Stops on its own when pass B reaches 625/625.
cd "D:/GERMANY/NOTES/R" || exit 1
NKEYS=$(grep -c '[^[:space:]]' groq_keys.txt)
CACHE=data/cache/qwen_qwen3_8-27b
count() { ls "$CACHE"/*.rds 2>/dev/null | wc -l; }

# Replace any B workers already running, rather than adding to them: a second
# worker on the same key doubles the token pressure on that key's per-minute
# bucket, which is what causes the long backoffs in the first place. Only pass-B
# processes are touched -- pass A and anything else is left alone.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='Rscript.exe'\" | Where-Object { \$_.CommandLine -match 'annotate.R\" \"B\"|annotate.R B ' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>/dev/null
sleep 2

# Clear stale claims left by workers killed mid-request, so the batches they
# held are not locked out for the claim TTL.
rm -rf "$CACHE/_claims"

echo "pass B at $(count)/625 -- launching on $NKEYS keys"
for k in $(seq 1 "$NKEYS"); do
  nohup Rscript R/04_llm_annotate.R B 900 NA 1 1 medium "$k" \
    > "logs_passB$k.txt" 2>&1 &
  sleep 1
done
echo "launched. check progress with:  bash R/status.sh"
