#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Keeps the annotation scheduler alive until every pass is complete.
#
# NOTE: pgrep does not exist in this Git-Bash environment. An earlier version of
# this file used `pgrep -f run_passes.sh` for its liveness check, which silently
# returned "not running" every time -- so the watchdog launched a fresh
# scheduler every five minutes and six of them ended up competing for the same
# per-key token bucket. Liveness is now tracked with a PID file and `kill -0`,
# which works here.
#
# Stops only when all three passes have reached 625/625, i.e. when there is
# nothing further any amount of budget could buy.
# ---------------------------------------------------------------------------
cd "D:/GERMANY/NOTES/R" || exit 1
PIDFILE=.scheduler.pid
LOG=logs_watchdog.txt

count()  { ls "$1"/*.rds 2>/dev/null | wc -l; }
alive()  { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

while true; do
  a=$(count data/cache/openai_gpt-oss-120b)
  b=$(count data/cache/qwen_qwen3_8-27b)
  c=$(count data/cache/openai_gpt-oss-safeguard-20b)
  echo "[$(date '+%a %H:%M')] A=$a B=$b C=$c" >> "$LOG"

  if [ "$a" -ge 625 ] && [ "$b" -ge 625 ] && [ "$c" -ge 625 ]; then
    echo "[$(date '+%a %H:%M')] all three passes complete -- watchdog exiting" >> "$LOG"
    rm -f "$PIDFILE"
    break
  fi

  if ! alive; then
    echo "[$(date '+%a %H:%M')] scheduler down -- starting it" >> "$LOG"
    nohup bash R/run_passes.sh 200 >> logs_scheduler.txt 2>&1 &
    echo $! > "$PIDFILE"
  fi

  sleep 300
done
