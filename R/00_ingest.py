"""
S0 -- INGEST
Stream the four raw JSONL dumps into a single columnar Parquet store.

Rationale: the raw corpus is 2.3 GB of JSON with ~100 fields per record, of which
this study uses 14. A one-time conversion to Parquet gives a ~20x size reduction
and lets every downstream R script query the corpus with arrow/duckdb instead of
holding it in memory.

Run:  python R/00_ingest.py
Out:  data/parquet/comments_raw.parquet
      data/derived/depth.parquet
"""
import duckdb, glob, os, sys, time, collections

ROOT = "D:/GERMANY/NOTES/R"
RAW = os.path.join(ROOT, "final data")
OUT = os.path.join(ROOT, "data/parquet/comments_raw.parquet")
DEPTH = os.path.join(ROOT, "data/derived/depth.parquet")

COLS = {
    "id": "VARCHAR", "link_id": "VARCHAR", "parent_id": "VARCHAR",
    "subreddit": "VARCHAR", "author": "VARCHAR", "author_fullname": "VARCHAR",
    "created_utc": "BIGINT", "body": "VARCHAR", "score": "BIGINT",
    "controversiality": "BIGINT", "is_submitter": "BOOLEAN",
    "permalink": "VARCHAR", "edited": "VARCHAR", "distinguished": "VARCHAR",
    "stickied": "BOOLEAN",
}
colspec = "{" + ", ".join(f"'{k}': '{v}'" for k, v in COLS.items()) + "}"

con = duckdb.connect()
con.execute("PRAGMA threads=4; PRAGMA memory_limit='3GB';")

files = sorted(glob.glob(os.path.join(RAW, "*.jsonl")))
print(f"[ingest] {len(files)} source files")

union_parts = []
for f in files:
    p = f.replace("\\", "/")
    union_parts.append(f"""
      SELECT *,
             -- the submission title survives only inside the permalink slug;
             -- it is the sole piece of post-level metadata in the dump.
             replace(split_part(permalink, '/', 6), '_', ' ') AS thread_slug
      FROM read_json('{p}', format='newline_delimited', columns={colspec},
                     ignore_errors=true, maximum_object_size=20000000)
    """)
sql_union = "\nUNION ALL\n".join(union_parts)

t0 = time.time()
con.execute(f"""
COPY (
  SELECT
      id, link_id, parent_id, subreddit, author, author_fullname,
      created_utc,
      to_timestamp(created_utc)              AS created_ts,
      strftime(to_timestamp(created_utc), '%Y-%m') AS ym,
      body, score, controversiality, is_submitter, stickied,
      permalink, thread_slug, edited, distinguished,
      (parent_id LIKE 't3_%')                AS is_top_level,
      length(body)                           AS n_chars
  FROM ({sql_union})
) TO '{OUT}' (FORMAT PARQUET, COMPRESSION ZSTD);
""")
print(f"[ingest] parquet written in {time.time()-t0:.0f}s")

n = con.execute(f"SELECT count(*) FROM read_parquet('{OUT}')").fetchone()[0]
print(f"[ingest] {n:,} rows -> {os.path.getsize(OUT)/1e6:.0f} MB parquet")

# ---- reply depth -------------------------------------------------------
# Depth needs the parent chain. Many parents are absent from the dump (only
# comments were retrieved, and only for the collection window), so depth is
# resolved iteratively and left NULL where the chain breaks.
print("[depth] resolving parent chains")
rows = con.execute(
    f"SELECT id, parent_id FROM read_parquet('{OUT}')").fetchall()
parent = dict(rows)
depth = {}

for start, _ in rows:
    if start in depth:
        continue
    stack, cur = [], start
    while cur not in depth:
        p = parent.get(cur)
        if p is None or len(p) < 4:        # parent absent from the dump
            depth[cur] = None
            break
        if p.startswith("t3_"):            # reached the submission itself
            depth[cur] = 0
            break
        par = p[3:]
        if par not in parent or len(stack) > 500:
            depth[cur] = None
            break
        stack.append(cur)
        cur = par
    base = depth[cur]
    while stack:                            # backfill the chain we walked
        c = stack.pop()
        base = None if base is None else base + 1
        depth[c] = base

known = sum(1 for v in depth.values() if v is not None)
print(f"[depth] resolved {known:,}/{len(depth):,} ({known/len(depth):.1%})")

import pandas as pd
dtab = pd.DataFrame({"id": list(depth.keys()), "depth": list(depth.values())})
dtab["depth"] = dtab["depth"].astype("Int32")
con.register("dtab_df", dtab)
con.execute(f"COPY dtab_df TO '{DEPTH}' (FORMAT PARQUET)")
print(f"[depth] written -> {DEPTH}")
con.close()
