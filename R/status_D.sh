#!/usr/bin/env bash
# Pass D status. The batch-50 full run and the batch-8 gold run live in separate
# cache namespaces because their batch composition differs; both are reported.
cd "D:/GERMANY/NOTES/R" || exit 1
python - <<'PY'
import json, glob, os, subprocess
b50 = glob.glob('data/cache/claude_cli_b50/*.json')
gold = glob.glob('data/cache/claude_cli_gold/*.json')
n = lambda fs: sum(len(json.load(open(f, encoding='utf-8'))['results']) for f in fs)
def bar(d, t, w=28):
    k = int(w * d / t) if t else 0
    return '[' + '#' * k + '.' * (w - k) + ']'
c50, cg = len(b50), len(gold)
print('=' * 62)
print(' pass D (claude via CLI)      ' + subprocess.run(
    ['date', '+%a %d %b  %H:%M:%S'], capture_output=True, text=True).stdout.strip())
print('=' * 62)
print(' full  {} {:>3}% {:>3}/100 calls   {:>5,}/4,997 comments'.format(
    bar(c50, 100), c50, c50, n(b50)))
print(' gold  {} {:>3}% {:>3}/45  calls   {:>5,}/358   comments'.format(
    bar(cg, 45), int(100 * cg / 45), cg, n(gold)))
print('-' * 62)
## Pick the newest run log by glob, not a hardcoded list -- an earlier version
## named run.txt/run2.txt explicitly and kept reporting a dead run's failures
## after run3 started.
run = glob.glob('logs_passD_run*.txt')
if run:
    log = max(run, key=os.path.getmtime)
    txt = open(log, encoding='utf-8', errors='replace').read().splitlines()
    fails = sum('FAILED' in l for l in txt)
    print(' last log : {}  ({} FAILED lines)'.format(log, fails))
    for l in txt[-3:]:
        print('   ' + l[:110])
alive = subprocess.run(['tasklist'], capture_output=True, text=True).stdout
print('-' * 62)
print(' driver running: ' + ('YES' if '04d_claude_cli' in alive or
      any('python' in l.lower() for l in alive.splitlines()[3:]) else 'no python procs'))
PY
