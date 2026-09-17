#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Re-fetch pass A's truncated batches, at full speed across all six keys.
#
#   1. deletes the cached batches that came back short, putting them back in
#      the work queue (their cache keys are unchanged, so nothing else would);
#   2. relaunches pass A with one independent loop per key.
#
# Why this is safe to run at speed now: 04_llm_annotate.R detects a short batch
# and retries it at double the completion ceiling before caching, so the failure
# that produced these gaps cannot recur silently. The ceiling is 3,000 tokens
# (measured completions are ~1,866), which reserves ~5,100 against the
# 8,000-per-minute per-key bucket -- 1.57 requests/minute/key, and 1.49 is used.
#
# Across six keys that is ~9 requests/minute when daily budget allows; the daily
# budget itself caps the day at roughly 300 calls.
#
# Usage: bash R/refetch_and_run.sh
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R" || exit 1
CACHE=data/cache/openai_gpt-oss-120b

echo "== before =="
Rscript R/refetch_truncated.R "$CACHE"

echo
echo "== deleting short batches =="
Rscript R/refetch_truncated.R "$CACHE" --delete

# Stop anything already working pass A, and release its claim locks, so the
# re-queued batches are not held for the 45-minute claim TTL.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='Rscript.exe'\" | Where-Object { \$_.CommandLine -match 'annotate.R\" \"A\"|annotate.R A ' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>/dev/null
sleep 2
rm -rf "$CACHE/_claims"

echo
echo "== relaunching pass A on 6 keys =="
nohup bash R/run_A_keys.sh > /dev/null 2>&1 &
sleep 8
echo "workers: $(ps -W 2>/dev/null | grep -ci rscript)"
echo
echo "watch it with:   bash R/status.sh"
echo "truncation check: Rscript R/check_truncation.R"
