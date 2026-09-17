"""
S7 -- SENTENCE EMBEDDINGS (the one Python sidecar)

Everything else in this study is R. Embedding is not, for one reason: there is
no GPU on this machine and no R binding to a modern sentence encoder that runs
acceptably on CPU. The dependency is declared rather than hidden, and the
output is Parquet, which R reads natively with arrow.

Model: BAAI/bge-small-en-v1.5 -- 33M parameters, 384 dimensions, near the top
of MTEB for its size class and small enough to embed a million short Reddit
comments on CPU in about an hour.

The script benchmarks itself before committing to the full run and falls back
to a stratified subset if the projection exceeds the time budget, rather than
discovering the problem four hours in.

Run:  python R/07_embed.py [max_minutes]
Out:  data/derived/embeddings.parquet   (id, e0..e383, float32)
      output/tables/embedding_bench.txt
"""
import os, sys, time
import numpy as np, pandas as pd, duckdb, torch

ROOT = "D:/GERMANY/NOTES/R"
CORPUS = f"{ROOT}/data/parquet/analysis_corpus.parquet"
OUT = f"{ROOT}/data/derived/embeddings.parquet"
BUDGET_MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 600.0
MODEL = "BAAI/bge-small-en-v1.5"
MAXLEN = 192          # covers the 99th percentile of comment length
BATCH = 256

# Prove the output path works BEFORE spending hours encoding. The first run of
# this script encoded the whole corpus and then died because pandas had no
# parquet engine installed, losing all of it.
os.makedirs(os.path.dirname(OUT), exist_ok=True)
_probe = f"{ROOT}/data/derived/_writeprobe.parquet"
pd.DataFrame({"id": ["probe"], "e0": [0.0]}).to_parquet(_probe, index=False)
assert pd.read_parquet(_probe).shape == (1, 2), "parquet round-trip failed"
os.remove(_probe)
print("[embed] output path verified")

torch.set_num_threads(os.cpu_count() or 4)
print(f"[embed] torch threads = {torch.get_num_threads()}")

from sentence_transformers import SentenceTransformer
t0 = time.time()
model = SentenceTransformer(MODEL, device="cpu")
model.max_seq_length = MAXLEN
print(f"[embed] model loaded in {time.time()-t0:.0f}s")

con = duckdb.connect()
df = con.execute(f"""
    SELECT id, subreddit, has_ai_ref, n_words, text
    FROM read_parquet('{CORPUS}')
""").df()
N = len(df)
print(f"[embed] corpus {N:,}")

# ---- benchmark -----------------------------------------------------------
bench = df.sample(2000, random_state=1)["text"].tolist()
t0 = time.time()
_ = model.encode(bench, batch_size=BATCH, show_progress_bar=False,
                 normalize_embeddings=True)
rate = len(bench) / (time.time() - t0)
proj = N / rate / 60
msg = (f"throughput {rate:.0f} docs/s  |  full corpus {N:,} docs "
       f"projected {proj:.0f} min  |  budget {BUDGET_MIN:.0f} min")
print(f"[embed] {msg}")

# ---- scope decision -------------------------------------------------------
if proj <= BUDGET_MIN:
    sub = df
    scope = f"FULL corpus, n={N:,}"
else:
    # Keep every comment carrying an AI reference (these are the ones the
    # classifier and the topic model actually work on), plus a random sample of
    # the rest so the relevance gate itself stays estimable.
    keep_n = int(rate * BUDGET_MIN * 60)
    ai = df[df.has_ai_ref]
    rest = df[~df.has_ai_ref]
    take_rest = max(0, keep_n - len(ai))
    if take_rest > 0 and take_rest < len(rest):
        rest = rest.sample(take_rest, random_state=1)
    elif take_rest <= 0:
        ai = ai.sample(keep_n, random_state=1)
        rest = rest.iloc[0:0]
    sub = pd.concat([ai, rest])
    scope = (f"SUBSET n={len(sub):,} (all {len(df[df.has_ai_ref]):,} with an AI "
             f"reference + {len(rest):,} sampled without) -- CPU time budget")
print(f"[embed] scope: {scope}")

with open(f"{ROOT}/output/tables/embedding_bench.txt", "w") as f:
    f.write(f"model: {MODEL}\nmax_seq_length: {MAXLEN}\ndevice: cpu\n"
            f"threads: {torch.get_num_threads()}\n{msg}\nscope: {scope}\n")

# ---- run ------------------------------------------------------------------
texts = sub["text"].tolist()
t0 = time.time()
embs = model.encode(texts, batch_size=BATCH, show_progress_bar=True,
                    normalize_embeddings=True, convert_to_numpy=True)
print(f"[embed] encoded {len(texts):,} in {(time.time()-t0)/60:.1f} min")

out = pd.DataFrame(embs.astype("float32"),
                   columns=[f"e{i}" for i in range(embs.shape[1])])
out.insert(0, "id", sub["id"].values)
out.to_parquet(OUT, compression="zstd", index=False)
print(f"[embed] wrote {OUT}  ({os.path.getsize(OUT)/1e6:.0f} MB, dim={embs.shape[1]})")
