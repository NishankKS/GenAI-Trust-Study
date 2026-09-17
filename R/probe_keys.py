"""Per-key capacity probe.

budget_check.py answers only "did this key return a per-day error", which cannot
tell a fresh key from one with 2% left -- and that difference decides how fast
pass B can run. Groq reports the real numbers in x-ratelimit-* response headers,
including the daily request bucket and the per-minute token bucket, so read the
headers directly with curl -D (urllib's default User-Agent is Cloudflare-blocked
with error 1010).

The probe is deliberately tiny (max_tokens 1) so it costs almost nothing.

Usage: python R/probe_keys.py <model>
"""
import json, subprocess, sys

ROOT  = "D:/GERMANY/NOTES/R"
model = sys.argv[1] if len(sys.argv) > 1 else "qwen/qwen3.8-27b"
keys  = [l.strip() for l in open(f"{ROOT}/groq_keys.txt", encoding="utf-8-sig")
         if l.strip() and not l.startswith("#")]

probe = json.dumps({"model": model,
                    "messages": [{"role": "user", "content": "ok"}],
                    "max_tokens": 1})

def headers_for(key):
    out = subprocess.run(
        ["curl", "-s", "-D", "-", "-o", "/dev/null", "-X", "POST",
         "https://api.groq.com/openai/v1/chat/completions",
         "-H", f"Authorization: Bearer {key}",
         "-H", "Content-Type: application/json",
         "--data-binary", probe],
        capture_output=True, text=True, timeout=90).stdout
    h = {}
    for line in out.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            h[k.strip().lower()] = v.strip()
    return h

def val(h, name):
    return h.get(name, "-")

print(f"{model}\n")
cols = (f"{'key':<4} {'status':<7} {'req/day':>13} {'tok/min':>14} "
        f"{'req reset':>11} {'tok reset':>11}")
print(cols); print("-" * len(cols))
for i, k in enumerate(keys, 1):
    h = headers_for(k)
    print(f"{i:<4} {val(h,'x-ratelimit-remaining-requests') and h.get('status','?'):<7}"
          f"{val(h,'x-ratelimit-remaining-requests')+'/'+val(h,'x-ratelimit-limit-requests'):>13} "
          f"{val(h,'x-ratelimit-remaining-tokens')+'/'+val(h,'x-ratelimit-limit-tokens'):>14} "
          f"{val(h,'x-ratelimit-reset-requests'):>11} "
          f"{val(h,'x-ratelimit-reset-tokens'):>11}")
