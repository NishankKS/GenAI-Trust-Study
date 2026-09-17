"""Pass D -- annotate the sample with Claude via the Claude Code CLI.

Why the CLI and not the Anthropic API: no API budget is available, but a Claude
Code subscription is. `claude -p` runs one headless, non-interactive session per
invocation, which is what makes this usable as a measurement instrument:

  * Each batch is a FRESH session. It carries none of the analysis context that
    an interactive session accumulates -- no gold labels, no validation tables,
    no prevalence estimates. The annotator is blind to the answer key, which is
    the whole point of a second annotator.
  * File tools are denied and the working directory is a scratch dir, so the
    session cannot read gold_labels.csv (or anything else) off disk. Without
    this the agent could trivially look up the answers. This is the single most
    important safeguard here -- do not remove it.
  * --system-prompt REPLACES Claude Code's default agent prompt rather than
    appending to it, so the model is doing classification, not agentics.

Deliberate parity with passes A/B/C, so pass D is comparable:
  * identical system prompt (dumped verbatim from 04_llm_annotate.R)
  * identical batch composition -- sample sorted by id, chunks of 8, so batch k
    holds exactly the same 8 comments it holds in every other pass
  * identical per-batch caching, so a re-run costs nothing and is resumable

The one thing the CLI cannot do that ellmer did is ENFORCE the schema. ellmer
passed a type_object and the model was structurally incapable of returning an
out-of-codebook label. Here the schema is only a prompt instruction, so every
response is validated against codebook_levels.json and a bad batch is retried
rather than written.

Usage:
  python R/04d_claude_cli.py [--limit N] [--workers N] [--model M] [--dry-run]
"""
import argparse, concurrent.futures as cf, hashlib, json, os, shutil
import subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path("D:/GERMANY/NOTES/R")
PASS = "D"
PROMPT_VERSION = "v5-full-codebook-b8"      # same prompt text as A/B/C
BATCH = 8
CACHE = ROOT / "data/cache/claude_cli"
CACHE_GOLD = ROOT / "data/cache/claude_cli_gold"
LOG = ROOT / "logs_passD.txt"

SCHEMA_CONTRACT = """

OUTPUT CONTRACT. Return ONLY a JSON object. No prose, no markdown fence, no
commentary before or after.
{"results":[{"id":"<exact id>","relevance":"...","stance":"...","dimension":"...","target":"...","name_calling":false,"vulgarity":false,"aspersion":false,"lying_accusation":false,"pejorative_speech":false,"identity_attack":false,"threat":false,"incivility_direction":"...","confidence":0.0}]}
Emit the seven incivility fields as SEPARATE BOOLEANS exactly as named above --
never as an array. confidence is a number 0-1. Return one object per comment,
for ALL of them, with each id copied exactly as given."""


## Resolving the CLI: prefer the REAL binary over npm's claude.cmd shim.
##
## A bare "claude" in subprocess raises WinError 2 (the shim is not an .exe), so
## it has to be resolved explicitly -- but resolving to the .cmd is worse than it
## looks. The shim spawns cmd.exe, which re-resolves the path to claude.exe on
## every call, and Claude Code auto-updates itself in place. A run of 100 calls
## spans long enough to hit that window: an update mid-run made 88 of 100 calls
## die with '"...\\claude.exe" is not recognized as an internal or external
## command'. Calling the .exe directly skips the cmd.exe layer entirely.
def _find_claude():
    direct = Path(os.environ.get("APPDATA", "")) / (
        "npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe")
    if direct.exists():
        return str(direct)
    shim = shutil.which("claude") or shutil.which("claude.cmd")
    if shim:                       # derive the .exe next to the shim if we can
        cand = (Path(shim).parent
                / "node_modules/@anthropic-ai/claude-code/bin/claude.exe")
        if cand.exists():
            return str(cand)
    return shim or shutil.which("claude.exe")


CLAUDE_BIN = _find_claude()
if CLAUDE_BIN is None:
    sys.exit("claude CLI not found on PATH")


def log(msg):
    line = f"[{time.strftime('%a %H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def load_inputs():
    import pyarrow.parquet as pq
    t = pq.read_table(ROOT / "data/derived/annotation_sample.parquet")
    cols = {c: t.column(c).to_pylist() for c in t.column_names}
    rows = [dict(zip(cols, vals)) for vals in zip(*cols.values())]
    rows.sort(key=lambda r: r["id"])            # same order as every other pass
    sys_prompt = (ROOT / "data/derived/prompt_sysfull.txt").read_text(encoding="utf-8")
    levels = json.loads((ROOT / "data/derived/codebook_levels.json").read_text(encoding="utf-8"))
    return rows, sys_prompt, levels


def make_user_block(chunk):
    """Byte-identical to make_user() in 04_llm_annotate.R."""
    parts = []
    for r in chunk:
        ctx = r.get("parent_text") or ""
        ctx = ctx[:400] if ctx.strip() else "(top-level comment)"
        parts.append(
            f"### id: {r['id']}\nSUBREDDIT: r/{r['subreddit']}\n"
            f"THREAD: {str(r['thread_slug'])[:90]}\nREPLYING TO: {ctx}\n"
            f"COMMENT: {str(r['text'])[:1800]}")
    return (f"Code each of the following {len(chunk)} comments. Return one "
            f"result per comment, with the id copied exactly.\n\n"
            + "\n\n".join(parts))


def cache_key(model, chunk):
    ids = ",".join(r["id"] for r in chunk)
    return hashlib.md5(f"{model}{PROMPT_VERSION}{PASS}{ids}".encode()).hexdigest()


def validate(payload, chunk, levels):
    """Return (rows, None) or (None, reason). The CLI enforces no schema, so
    anything that would corrupt the labels table is rejected here."""
    if not isinstance(payload, dict) or "results" not in payload:
        return None, "no results key"
    rows = payload["results"]
    if not isinstance(rows, list):
        return None, "results not a list"
    want = [r["id"] for r in chunk]
    got = [r.get("id") for r in rows if isinstance(r, dict)]
    if got != want:
        return None, f"id mismatch (got {len(got)} of {len(want)})"
    for r in rows:
        for f in ("relevance", "stance", "dimension", "target", "incivility_direction"):
            if r.get(f) not in levels[f]:
                return None, f"bad {f}={r.get(f)!r}"
        for f in levels["incivility_fields"]:
            if not isinstance(r.get(f), bool):
                return None, f"{f} not boolean"
        c = r.get("confidence")
        if not isinstance(c, (int, float)) or not 0 <= c <= 1:
            return None, f"bad confidence={c!r}"
    return rows, None


def extract_json(text):
    """The model is told to emit bare JSON, but strip a fence if one appears."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        t = t.rsplit("```", 1)[0]
    i, j = t.find("{"), t.rfind("}")
    if i == -1 or j == -1:
        return None
    try:
        return json.loads(t[i:j + 1])
    except Exception:
        return None


def annotate(chunk, sys_prompt, levels, model, attempts=3):
    """One batch -> validated rows. Runs in a scratch cwd with file tools denied
    so the session cannot read the project's gold labels."""
    global CLAUDE_BIN
    ## The codebook goes in the MESSAGE BODY, not --system-prompt.
    ## Measured on CLI 2.1.260: with --system-prompt the codebook did not reach
    ## the model at all, and it answered with invented labels that look
    ## plausible but are not in the scheme -- relevance "on_topic", stance
    ## "pro_openai", dimension "platform_integrity". Nothing errored; only the
    ## level validation below caught it. Carrying the codebook in the message is
    ## the only placement observed to reliably take effect.
    user = sys_prompt + "\n\n" + make_user_block(chunk) + SCHEMA_CONTRACT
    last = "no attempt"
    for a in range(1, attempts + 1):
        work = tempfile.mkdtemp(prefix="passD_")
        try:
            p = subprocess.run(
                [CLAUDE_BIN, "-p",
                 "--model", model,
                 "--output-format", "json",
                 "--max-turns", "1",
                 "--disallowed-tools",
                 "Bash Edit Write Read Glob Grep WebSearch WebFetch NotebookEdit Task"],
                input=user, capture_output=True, text=True,
                encoding="utf-8", errors="replace",
                cwd=work, timeout=600)
            if p.returncode != 0:
                last = f"cli exit {p.returncode}: {(p.stderr or '')[:120]}"
                continue
            try:
                out = json.loads(p.stdout)
            except Exception:
                last = "stdout not JSON"
                continue
            ## stdout is normally the CLI envelope, but some flag combinations
            ## make it the model's bare answer instead. Accept either.
            if "results" in out:
                payload, cost = out, 0.0
            else:
                if out.get("is_error"):
                    last = f"is_error: {str(out.get('result'))[:120]}"
                    continue
                payload = extract_json(str(out.get("result", "")))
                cost = out.get("total_cost_usd", 0.0)
            if payload is None:
                last = "unparseable JSON"
                continue
            rows, why = validate(payload, chunk, levels)
            if rows is None:
                last = why
                continue
            return rows, cost, None
        except subprocess.TimeoutExpired:
            last = "timeout 600s"
        except Exception as e:
            last = f"{type(e).__name__}: {e}"
        finally:
            shutil.rmtree(work, ignore_errors=True)
        ## Claude Code auto-updates itself in place, and during the swap the
        ## binary is briefly absent (WinError 2) or unrunnable. Retrying
        ## immediately just burns all three attempts inside the same window --
        ## that cost 66 of 79 calls on one run and 88 of 100 on another. Back
        ## off and re-resolve the path, since the update can also move it.
        time.sleep(5 * a)
        again = _find_claude()
        if again:
            CLAUDE_BIN = again
    return None, 0.0, last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold-only", action="store_true",
                    help="annotate only the 358 human-coded comments (45 batches). "
                         "This is the cheap decision experiment: it yields pass D's "
                         "scores against the same human gold every other instrument "
                         "in validation.csv was scored on, for ~7%% of the cost of "
                         "the full sample. Batches are packed from the gold ids "
                         "alone, so a batch holds different neighbours than the "
                         "corresponding A/B/C batch -- fine for scoring against "
                         "gold, which is per-comment, but it means these cache "
                         "entries are NOT interchangeable with a later full run.")
    ap.add_argument("--batch", type=int, default=BATCH,
                    help="comments per call. 8 matches passes A/B/C. Larger is "
                         "cheaper: the 1,839-token codebook and each call's cold-"
                         "start harness context are paid ONCE PER CALL, so at "
                         "batch 8 the codebook alone is resent 625 times (1.15M "
                         "tokens, ~2x the corpus text itself). The ceiling is "
                         "output, not context: ~62 tokens per record against a "
                         "128,000 max_tokens cap is ~2,000 records per call, and "
                         "streaming does not raise that cap. The real limit is "
                         "whether accuracy and per-position completeness hold -- "
                         "measure with score_passes.py before trusting a size.")
    ap.add_argument("--limit", type=int, default=0, help="max batches this run (0 = all)")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--model", default="claude-opus-5")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    global CACHE
    bsize = args.batch
    if args.gold_only:
        CACHE = CACHE_GOLD
    ## Batch size changes batch composition, so entries from different sizes are
    ## not interchangeable -- give each its own namespace.
    if args.batch != 8:
        CACHE = CACHE.parent / f"{CACHE.name}_b{args.batch}"
    ## Same for the model. cache_key() already hashes the model in, so entries
    ## never collide -- but score_passes.py reads a whole directory and keys by
    ## comment id, so two models sharing a directory would silently overwrite
    ## each other and produce a blended, meaningless "pass D".
    if args.model != "claude-opus-5":
        CACHE = CACHE.parent / f"{CACHE.name}_{args.model.replace('.', '-')}"
    CACHE.mkdir(parents=True, exist_ok=True)
    rows, sys_prompt, levels = load_inputs()
    if args.gold_only:
        import csv
        gold = {r["id"] for r in csv.DictReader(
            open(ROOT / "data/derived/gold_labels.csv", encoding="utf-8-sig"))}
        rows = [r for r in rows if r["id"] in gold]
        log(f"gold-only: {len(rows)} of {len(gold)} human-coded comments matched")
    batches = [rows[i:i + bsize] for i in range(0, len(rows), bsize)]
    todo = [(k, c) for k, c in enumerate(batches)
            if not (CACHE / f"{cache_key(args.model, c)}.json").exists()]
    log(f"pass D | {args.model} | {len(rows)} items | {len(batches)} batches | "
        f"{len(batches) - len(todo)} cached | {len(todo)} outstanding")
    if args.limit:
        todo = todo[:args.limit]
        log(f"limit: this run will attempt {len(todo)} batches")
    if args.dry_run or not todo:
        return

    spent, ok, bad = 0.0, 0, 0
    t0 = time.time()

    def run(item):
        k, chunk = item
        res, cost, err = annotate(chunk, sys_prompt, levels, args.model)
        if res is not None:
            (CACHE / f"{cache_key(args.model, chunk)}.json").write_text(
                json.dumps({"ids": [r["id"] for r in chunk], "results": res}),
                encoding="utf-8")
        return k, res, cost, err

    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        for k, res, cost, err in ex.map(run, todo):
            spent += cost
            if res is None:
                bad += 1
                log(f"batch {k}: FAILED -- {err}")
            else:
                ok += 1
                if ok % 10 == 0 or ok == 1:
                    done = len(batches) - len(todo) + ok
                    el = (time.time() - t0) / 60
                    log(f"{done}/{len(batches)} cached | {ok} ok {bad} bad | "
                        f"{el:.1f} min | ${spent:.2f} plan usage")

    log(f"run finished: {ok} ok, {bad} failed, {(time.time()-t0)/60:.1f} min, "
        f"${spent:.2f} plan usage")
    log(f"cached now: {len(list(CACHE.glob('*.json')))}/{len(batches)}")


if __name__ == "__main__":
    main()
