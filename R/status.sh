#!/usr/bin/env bash
# One-shot status of the three annotation passes.
#   bash R/status.sh          print once
#   bash R/status.sh watch    refresh every 3 minutes until all passes finish
cd "D:/GERMANY/NOTES/R" || exit 1

snap() {
  A=$(ls data/cache/openai_gpt-oss-120b/*.rds          2>/dev/null | wc -l)
  B=$(ls data/cache/qwen_qwen3_8-27b/*.rds             2>/dev/null | wc -l)
  C=$(ls data/cache/openai_gpt-oss-safeguard-20b/*.rds 2>/dev/null | wc -l)
  WA=$(ps -W 2>/dev/null | grep -c "Rscript" )
  TOT=$((A+B+C))
  bar() {  # $1 done, $2 total, width 28
    local f=$(( $1 * 28 / $2 )); local i
    printf "["
    for ((i=0;i<28;i++)); do if [ $i -lt $f ]; then printf "#"; else printf "."; fi; done
    printf "]"
  }
  echo "=============================================================="
  echo " annotation status          $(date '+%a %d %b  %H:%M:%S')"
  echo "=============================================================="
  printf " A  gpt-oss-120b    %s %3d%%  %3d/625  left %3d\n" "$(bar $A 625)" $((A*100/625)) $A $((625-A))
  printf " B  qwen3.8-27b     %s %3d%%  %3d/625  left %3d\n" "$(bar $B 625)" $((B*100/625)) $B $((625-B))
  printf " C  safeguard-20b   %s %3d%%  %3d/625  left %3d\n" "$(bar $C 625)" $((C*100/625)) $C $((625-C))
  echo " --------------------------------------------------------------"
  printf " TOTAL              %s %3d%%  %d/1875  left %d\n" "$(bar $TOT 1875)" $((TOT*100/1875)) $TOT $((1875-TOT))
  # Batch count x 8 OVERSTATES what is held: a response cut short by the
  # completion-token ceiling still parses as valid JSON, so a short batch is
  # cached as a success and the missing comments disappear silently. Report the
  # row counts actually present instead.
  python R/annot_counts.py 2>/dev/null
  echo " R processes running: $WA"
  tail -1 logs_A_supervisor.txt 2>/dev/null | sed 's/^/ A supervisor: /'
  echo
}

if [ "${1:-}" = "watch" ]; then
  while true; do
    snap
    A=$(ls data/cache/openai_gpt-oss-120b/*.rds 2>/dev/null | wc -l)
    B=$(ls data/cache/qwen_qwen3_8-27b/*.rds 2>/dev/null | wc -l)
    C=$(ls data/cache/openai_gpt-oss-safeguard-20b/*.rds 2>/dev/null | wc -l)
    [ "$A" -ge 625 ] && [ "$B" -ge 625 ] && [ "$C" -ge 625 ] && { echo "ALL PASSES COMPLETE"; break; }
    sleep 180
  done
else
  snap
fi
