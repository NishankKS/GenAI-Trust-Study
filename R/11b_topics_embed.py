"""
S11b -- DATA-DRIVEN TOPICS FROM EMBEDDINGS

The counterpart to the seeded LDA in R/11_topics.R. Where that model is told
what to look for, this one is told nothing: it reduces the sentence embeddings,
clusters them by density, and reads keywords off each cluster with c-TF-IDF.
Its job is to find the themes the seed list did not anticipate, and to give the
seeded solution something independent to be checked against.

HDBSCAN rather than k-means, because density clustering is allowed to leave
comments unassigned instead of forcing every off-topic remark into a theme --
which matters in a corpus where a large minority of comments are not really
about anything.

Run:  python R/11b_topics_embed.py [n_sample]
Out:  data/derived/topics_embedding.parquet   (id, cluster)
      output/tables/topic_embedding_terms.csv
"""
import os, sys, time
import numpy as np, pandas as pd, duckdb
from sklearn.decomposition import PCA
import umap
from sklearn.cluster import HDBSCAN, MiniBatchKMeans
from sklearn.feature_extraction.text import CountVectorizer

ROOT = "D:/GERMANY/NOTES/R"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 120_000
MIN_CLUSTER = 250

con = duckdb.connect()
print("[S11b] loading embeddings for relevant comments")
# Prefer the distilled relevance decision; fall back to the lexical prefilter.
try:
    df = con.execute(f"""
        SELECT e.*, c.text, c.subreddit
        FROM read_parquet('{ROOT}/data/derived/embeddings.parquet') e
        JOIN read_parquet('{ROOT}/data/parquet/analysis_corpus.parquet') c USING (id)
        JOIN read_parquet('{ROOT}/data/derived/distilled_preds.parquet') p USING (id)
        WHERE p.pred_relevance = 'relevant'
    """).df()
    src = "distilled relevance"
except Exception:
    df = con.execute(f"""
        SELECT e.*, c.text, c.subreddit
        FROM read_parquet('{ROOT}/data/derived/embeddings.parquet') e
        JOIN read_parquet('{ROOT}/data/parquet/analysis_corpus.parquet') c USING (id)
        WHERE c.has_ai_ref
    """).df()
    src = "lexical prefilter"
print(f"[S11b] {len(df):,} comments ({src})")

if len(df) > N:
    df = df.sample(N, random_state=1).reset_index(drop=True)
    print(f"[S11b] clustering a random {N:,}")

ecols = [c for c in df.columns if c.startswith("e") and c[1:].isdigit()]
X = df[ecols].to_numpy(dtype="float32")

# PCA first (cheap denoising), then UMAP. The UMAP step is not optional: HDBSCAN
# finds density, and 50-dimensional embedding space is too sparse to have any --
# a PCA-only pipeline left 95.8% of comments unassigned and produced three
# degenerate clusters. Projecting to 5 dimensions with a cosine metric is the
# step that creates the density structure density-clustering needs.
t0 = time.time()
Xp = PCA(n_components=50, random_state=1).fit_transform(X)
print(f"[S11b] PCA -> {Xp.shape[1]}d in {time.time()-t0:.0f}s")

t0 = time.time()
Xu = umap.UMAP(n_neighbors=15, n_components=5, min_dist=0.0,
               metric="cosine", random_state=1, verbose=False).fit_transform(Xp)
print(f"[S11b] UMAP -> {Xu.shape[1]}d in {(time.time()-t0)/60:.1f} min")
Xp = Xu

# Density clustering first, reported whatever it finds. On this corpus it finds
# very little: comments about AI form a continuum rather than well-separated
# density peaks, so HDBSCAN collapses to a couple of clusters. That is itself
# worth reporting -- it is evidence about the corpus, not a bug to hide.
t0 = time.time()
hdb = HDBSCAN(min_cluster_size=MIN_CLUSTER, min_samples=10,
              cluster_selection_method="leaf", n_jobs=-1)
hlab = hdb.fit_predict(Xp)
n_clust = len(set(hlab)) - (1 if -1 in hlab else 0)
noise = float((hlab == -1).mean())
print(f"[S11b] HDBSCAN(leaf): {n_clust} clusters, {noise:.1%} unassigned, "
      f"{time.time()-t0:.0f}s")

# For the cross-check against the seeded LDA we need a partition at comparable
# granularity, so a matched-K k-means is fitted alongside. Forcing every comment
# into a cluster is a real cost -- it is exactly what HDBSCAN was chosen to
# avoid -- but it makes the alignment matrix and NMI interpretable, and the
# density result above is reported next to it rather than replaced by it.
K_MATCH = int(os.environ.get("K_MATCH", "14"))
t0 = time.time()
klab = MiniBatchKMeans(n_clusters=K_MATCH, random_state=1, n_init=10,
                       batch_size=4096).fit_predict(Xp)
print(f"[S11b] k-means K={K_MATCH} in {time.time()-t0:.0f}s "
      f"(matched to the seeded LDA solution)")

USE = os.environ.get("CLUSTERER", "kmeans")
lab = klab if USE == "kmeans" else hlab
print(f"[S11b] partition used for the alignment: {USE}")

df["cluster"] = lab
df["hdbscan_cluster"] = hlab
df[["id", "cluster", "hdbscan_cluster"]].to_parquet(
    f"{ROOT}/data/derived/topics_embedding.parquet", index=False)

# ---- c-TF-IDF: what distinguishes each cluster's language ------------------
print("[S11b] extracting cluster keywords (c-TF-IDF)")
docs = df.groupby("cluster")["text"].apply(lambda s: " ".join(s.astype(str)))
# sklearn's English list keeps the conversational filler that dominates Reddit
# text, and contraction fragments survive tokenisation ("don", "ve", "ll").
# Without these the cluster keywords are unreadable and the topics look
# identical to one another. Mirrors the removals used by the seeded LDA in R.
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS
EXTRA = {"just", "like", "don", "ve", "ll", "re", "im", "id", "youre", "thats",
         "doesnt", "didnt", "isnt", "dont", "cant", "wont", "ive", "really",
         "actually", "people", "think", "know", "make", "makes", "want", "way",
         "ways", "things", "thing", "good", "better", "use", "using", "used",
         "work", "works", "time", "lot", "going", "got", "say", "says", "said",
         "need", "needs", "look", "looks", "pretty", "sure", "yeah", "gonna"}
cv = CountVectorizer(stop_words=list(ENGLISH_STOP_WORDS | EXTRA),
                     ngram_range=(1, 2), min_df=2, max_features=60_000)
C = cv.fit_transform(docs.values)
words = np.array(cv.get_feature_names_out())

# Densify first: dividing a sparse matrix by a column vector yields np.matrix,
# whose .multiply() result collapses to a 0-d array when wrapped in np.asarray.
# The cluster count is small, so a dense (clusters x vocab) array is cheap.
Cd = np.asarray(C.todense(), dtype="float64")
tf = Cd / np.maximum(Cd.sum(axis=1, keepdims=True), 1)   # term freq within cluster
n_docs = Cd.shape[0]
df_t = (Cd > 0).sum(axis=0)
idf = np.log(1 + n_docs / np.maximum(df_t, 1))
ctfidf = tf * idf

rows = []
sizes = df.groupby("cluster").size()
for i, cl in enumerate(docs.index):
    top = words[np.argsort(ctfidf[i])[::-1][:15]]
    rows.append({"cluster": int(cl), "n": int(sizes[cl]),
                 "share": round(float(sizes[cl] / len(df)), 4),
                 "terms": ", ".join(top)})
out = pd.DataFrame(rows).sort_values("n", ascending=False)
out.to_csv(f"{ROOT}/output/tables/topic_embedding_terms.csv", index=False)
print(out.head(20).to_string(index=False))
print(f"[S11b] wrote {len(out)} clusters")
