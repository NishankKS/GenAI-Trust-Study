"""Score every LLM pass against the human gold standard, on one test split.

Why this exists rather than reading output/tables/validation.csv: that file was
built on 09-02, when pass B held ~2,700 labels and C ~4,500. Both are now
complete and A has moved, so its numbers describe instruments that no longer
exist. Several of its worst results (pass A stance macro-F1 on n_test=14) were
small-sample artifacts, not measurements.

Scoring rules, chosen to match what validation.csv reports:
  * scored on gold_split == "test" (n=150) -- the same split the corpus-wide
    instruments were scored on, so rows stay comparable
  * macro F1, accuracy, Cohen's kappa per construct
  * n is per-pass, since a pass only scores the gold comments it actually
    labelled; a pass with thin coverage gets a small, clearly-reported n rather
    than a silently flattering one

Usage: python R/score_passes.py [--split test|dev|all]
"""
import argparse, csv, glob, json
from pathlib import Path
from sklearn.metrics import f1_score, accuracy_score, cohen_kappa_score

ROOT = Path("D:/GERMANY/NOTES/R")
INCIV = ["name_calling", "vulgarity", "aspersion", "lying_accusation",
         "pejorative_speech", "identity_attack", "threat"]


def load_gold(split):
    rows = list(csv.DictReader(
        open(ROOT / "data/derived/gold_labels.csv", encoding="utf-8-sig")))
    if split != "all":
        rows = [r for r in rows if r["gold_split"] == split]
    out = {}
    for r in rows:
        out[r["id"]] = {
            "relevance": r["relevance"],
            "stance": r["stance"],
            "any_incivility": r["any_incivility"].strip().upper() == "TRUE",
        }
    return out


def load_parquet_pass(letter):
    """A/B/C come from the ellmer parquets."""
    import pyarrow.parquet as pq
    p = ROOT / f"data/derived/llm_labels_{letter}.parquet"
    if not p.exists():
        return {}
    t = pq.read_table(p)
    cols = {c: t.column(c).to_pylist() for c in t.column_names}
    out = {}
    for vals in zip(*cols.values()):
        r = dict(zip(cols, vals))
        rec = {"relevance": r.get("relevance"), "stance": r.get("stance")}
        if all(f in r for f in INCIV):
            rec["any_incivility"] = any(bool(r[f]) for f in INCIV)
        out[r["id"]] = rec
    return out


def load_cli_pass(cache_dir):
    """Pass D comes from the CLI cache (one JSON file per batch)."""
    out = {}
    for f in glob.glob(str(ROOT / cache_dir / "*.json")):
        for r in json.loads(Path(f).read_text(encoding="utf-8"))["results"]:
            out[r["id"]] = {
                "relevance": r.get("relevance"),
                "stance": r.get("stance"),
                "any_incivility": any(bool(r.get(f)) for f in INCIV),
            }
    return out


def score(name, preds, gold):
    rows = []
    for construct in ("relevance", "stance", "any_incivility"):
        pairs = [(g[construct], preds[i].get(construct))
                 for i, g in gold.items()
                 if i in preds and preds[i].get(construct) is not None]
        if not pairs:
            rows.append((name, construct, 0, None, None, None))
            continue
        y, yh = [str(a) for a, _ in pairs], [str(b) for _, b in pairs]
        rows.append((name, construct, len(pairs),
                     f1_score(y, yh, average="macro", zero_division=0),
                     accuracy_score(y, yh),
                     cohen_kappa_score(y, yh)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test", choices=["test", "dev", "all"])
    args = ap.parse_args()

    gold = load_gold(args.split)
    passes = [
        ("A gpt-oss-120b", load_parquet_pass("A")),
        ("B qwen3.8-27b", load_parquet_pass("B")),
        ("C safeguard-20b", load_parquet_pass("C")),
        ("D claude-opus-5", load_cli_pass("data/cache/claude_cli_gold")),
    ]

    print(f"\ngold split: {args.split}  (n={len(gold)})\n")
    hdr = f"{'pass':<17} {'construct':<15} {'n':>4} {'macroF1':>8} {'acc':>7} {'kappa':>7}"
    print(hdr); print("-" * len(hdr))
    out = []
    for name, preds in passes:
        for row in score(name, preds, gold):
            n, f1, acc, k = row[2], row[3], row[4], row[5]
            fmt = lambda v: f"{v:.3f}" if v is not None else "  -  "
            print(f"{row[0]:<17} {row[1]:<15} {n:>4} {fmt(f1):>8} {fmt(acc):>7} {fmt(k):>7}")
            out.append(row)
        print()

    dest = ROOT / "output/tables/pass_comparison.csv"
    with open(dest, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["pass", "construct", "n", "macro_f1", "accuracy", "kappa"])
        for r in out:
            w.writerow([r[0], r[1], r[2],
                        None if r[3] is None else round(r[3], 4),
                        None if r[4] is None else round(r[4], 4),
                        None if r[5] is None else round(r[5], 4)])
    print(f"written: {dest}")


if __name__ == "__main__":
    main()
