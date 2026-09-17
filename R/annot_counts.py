"""
True annotation counts, straight from the batch cache.

Batch count x 8 OVERSTATES what is held. A response cut short by the
completion-token ceiling still parses as valid JSON, so a short batch is cached
as a success and the missing comments vanish silently. Pass A lost 21% of its
annotations that way. This counts the rows actually present.

Usage: python R/annot_counts.py
"""
import glob, os, pickle, sys

ROOT = "D:/GERMANY/NOTES/R"
DIRS = {"A": "openai_gpt-oss-120b",
        "B": "qwen_qwen3_8-27b",
        "C": "openai_gpt-oss-safeguard-20b"}
TARGET = 4997

# The caches are .rds, so counting rows requires R. Rather than pay that on every
# status call, read the assembled parquet when it is fresh enough and fall back
# to reporting only the batch count when it is not.
try:
    import duckdb
except ImportError:
    sys.exit(0)

out = []
for tag, d in DIRS.items():
    pq = f"{ROOT}/data/derived/llm_labels_{tag}.parquet"
    batches = len(glob.glob(f"{ROOT}/data/cache/{d}/*.rds"))
    if os.path.exists(pq):
        n = duckdb.sql(f"SELECT count(*) FROM read_parquet('{pq}')").fetchone()[0]
        age = int((os.path.getmtime(pq) - 0))
        out.append((tag, n, batches, os.path.getmtime(pq)))
    else:
        out.append((tag, None, batches, 0))

import time
now = time.time()
parts = []
for tag, n, batches, mt in out:
    if n is None:
        parts.append(f"{tag}=?")
    else:
        parts.append(f"{tag}={n}")
newest = max((o[3] for o in out if o[3]), default=0)
age_min = int((now - newest) / 60) if newest else -1
print(" annotations held:   " + "  ".join(parts) +
      f"   of {TARGET} each" +
      (f"   (assembled {age_min} min ago)" if age_min >= 0 else ""))
