"""
Preflight daily-budget probe.

Groq's daily token limit (200,000 per key per model) is a ROLLING 24-hour
window, so a model can be exhausted now and usable in an hour. A pass launched
against an exhausted model does not fail fast: ellmer retries the 429 internally
against retry-after values of 10-20 minutes, so the workers sit idle instead of
letting another pass use the time.

This probe asks each key whether the model has budget, cheaply, and prints
AVAILABLE or EXHAUSTED so the scheduler can skip a pass instead of blocking on
it. Exit code 0 = at least one key has budget, 1 = none do.

Usage: python R/budget_check.py <model>
"""
import json, re, subprocess, sys, time

ROOT = "D:/GERMANY/NOTES/R"
model = sys.argv[1] if len(sys.argv) > 1 else "openai/gpt-oss-120b"
keys = [l.strip() for l in open(f"{ROOT}/groq_keys.txt", encoding="utf-8-sig")
        if l.strip() and not l.startswith("#")]

# The probe must be cheap when it PASSES and still fail when the bucket is
# nearly empty. Groq checks prompt + max_tokens against the remaining daily
# budget before running anything, so a tiny prompt with a large max_tokens
# reservation does both: it is refused when fewer than ~6,000 tokens remain,
# and costs only a handful of tokens when it succeeds.
#
# The earlier version sent a 2,500-token prompt, which meant every budget check
# burned ~2,500 tokens per key per model -- self-defeating for a probe whose job
# is to conserve budget.
probe = json.dumps({"model": model,
                    "messages": [{"role": "user", "content": "ok"}],
                    "max_tokens": 4700})

def ask(key):
    out = subprocess.run(
        ["curl", "-s", "-X", "POST",
         "https://api.groq.com/openai/v1/chat/completions",
         "-H", f"Authorization: Bearer {key}",
         "-H", "Content-Type: application/json",
         "--data-binary", probe],
        capture_output=True, text=True, timeout=90).stdout
    try:
        return json.loads(out)
    except Exception:
        return None


# Groq enforces TWO token limits and they must not be confused:
#   TPM  8,000 per key per MINUTE, shared across models -- transient.
#   TPD  200,000 per key per MODEL per DAY -- the one that decides whether a
#        pass can run at all.
# Because the probe reserves 6,000 tokens, which is most of the per-minute
# bucket, a busy key refuses on TPM while having plenty of daily budget left.
# Treating that as exhaustion made the scheduler skip passes it could have run.
available, details, usable = 0, [], []
for i, k in enumerate(keys, 1):
    d = ask(k)
    if d is None:
        details.append(f"key{i}: unreadable response")
        continue
    msg = d.get("error", {}).get("message", "")

    if msg and "per minute" in msg.lower():
        time.sleep(8)                       # TPM recovers in seconds; TPD does not
        d2 = ask(k)
        msg = (d2 or {}).get("error", {}).get("message", "") if d2 else ""
        if msg and "per minute" in msg.lower():
            available += 1; usable.append(i)
            details.append(f"key{i}: AVAILABLE (per-minute limit only)")
            continue

    if not msg:
        available += 1; usable.append(i)
        details.append(f"key{i}: AVAILABLE")
    else:
        m = re.search(r"Limit (\d+), Used (\d+)", msg)
        if m and "per day" in msg.lower():
            lim, used = int(m.group(1)), int(m.group(2))
            details.append(f"key{i}: daily {used:,}/{lim:,} ({lim - used:,} left)")
        else:
            details.append(f"key{i}: {msg[:70]}")

print(f"{model}: {available}/{len(keys)} keys with budget")
for d in details:
    print("   ", d)
# The scheduler reads this to launch workers only on keys that can actually
# serve them; a worker on an exhausted key blocks inside ellmer's retry loop.
with open(f"{ROOT}/.usable_keys", "w") as f:
    f.write(" ".join(str(i) for i in usable))
sys.exit(0 if available else 1)
