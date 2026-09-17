"""
S2c -- SAMPLING DIAGNOSTICS

Selection within strata is systematic 1-in-k from a time-ordered frame, and it
begins at the first unit of each stratum rather than at a randomly chosen start.
Under a fixed start the realised sample is determined once the frame ordering is
fixed, so pi_h = n_h/N_h is a nominal rate rather than a realised randomisation
probability. That is defensible only if the frame ordering is unrelated to the
constructs, which is an assumption and can be tested.

Two tests are run.

  (1) BALANCE. Compare the design-weighted sample with the population on
      observable characteristics not used to build the strata. If the fixed
      start had selected a systematically peculiar subset, weighted sample
      means would not reproduce population means.

  (2) RANDOMISATION REFERENCE. Draw B systematic samples from the same frame
      with the same k but a RANDOM start, and locate the realised fixed-start
      sample in the resulting distribution of each statistic. A fixed start is
      benign exactly when the sample it produces is unremarkable against the
      randomised-start samples it could have produced.

Out: output/tables/sampling_balance.csv, sampling_randomisation.csv
"""
import numpy as np
import pandas as pd

ROOT = "/home/nishanksatish/Documents/Final_R/R"
rng = np.random.default_rng(20260901)
B = 500

ac = pd.read_parquet(f"{ROOT}/data/parquet/analysis_corpus.parquet",
                     columns=["id", "subreddit", "created_utc", "n_words", "depth",
                              "caps_ratio", "n_2ndperson", "n_links", "score",
                              "has_ai_ref", "is_top_level"])
samp = pd.read_parquet(f"{ROOT}/data/derived/annotation_sample.parquet",
                       columns=["id", "stratum", "N_h", "n_h", "pi_h", "w_h", "eligible"])

# rebuild the stratum labels exactly as the sampling stage did
ac["len_band"] = pd.cut(ac["n_words"], bins=[3, 15, 50, np.inf],
                        labels=["short", "medium", "long"])
ac["stratum"] = (ac["subreddit"] + "|" +
                 np.where(ac["has_ai_ref"], "airef", "noref") + "|" +
                 ac["len_band"].astype(str))
ac = ac[ac["len_band"].notna()].reset_index(drop=True)
ac["ym"] = pd.to_datetime(ac["created_utc"], unit="s", utc=True).dt.strftime("%Y-%m")

S = samp[samp["eligible"]].merge(ac, on=["id", "stratum"], how="inner")
VARS = ["n_words", "depth", "caps_ratio", "n_2ndperson", "n_links", "score",
        "is_top_level"]
for d in (ac, S):
    d["depth"] = d["depth"].fillna(-1).astype(float)
    d["is_top_level"] = d["is_top_level"].astype(float)

# ---- (1) balance: population mean vs design-weighted sample mean -------------
rows = []
for v in VARS:
    pop = ac[v].mean()
    wtd = np.average(S[v], weights=S["w_h"])
    sd = ac[v].std()
    rows.append(dict(variable=v, population=round(pop, 4), weighted_sample=round(wtd, 4),
                     abs_diff=round(abs(wtd - pop), 4),
                     std_diff=round(abs(wtd - pop) / sd, 4)))
for m in sorted(ac["ym"].unique()):
    pop = (ac["ym"] == m).mean()
    wtd = np.average((S["ym"] == m).astype(float), weights=S["w_h"])
    rows.append(dict(variable=f"month {m}", population=round(pop, 4),
                     weighted_sample=round(wtd, 4), abs_diff=round(abs(wtd - pop), 4),
                     std_diff=np.nan))
bal = pd.DataFrame(rows)
bal.to_csv(f"{ROOT}/output/tables/sampling_balance.csv", index=False)
print("BALANCE: design-weighted sample against the population\n")
print(bal.to_string(index=False))
print(f"\nlargest standardised difference on a continuous variable: "
      f"{bal['std_diff'].max():.4f}")
print(f"largest absolute difference on a monthly share: "
      f"{bal[bal.variable.str.startswith('month')]['abs_diff'].max():.4f}")

# ---- (2) randomisation reference --------------------------------------------
# For each stratum, order by time (as the sampling stage did) and take every
# k-th unit, starting at a random offset. Repeat B times.
ac_sorted = ac.sort_values(["stratum", "created_utc"]).reset_index(drop=True)
alloc = samp.groupby("stratum").agg(n_h=("n_h", "first")).reset_index()
groups = {s: g.index.to_numpy() for s, g in ac_sorted.groupby("stratum")}
nh = dict(zip(alloc["stratum"], alloc["n_h"]))

def systematic(start_frac):
    """The selection rule exactly as the sampling stage applies it: within a
    stratum ordered by time, keep the comment whose zero-based rank j satisfies
    (j - offset) mod k < 1, for k = N_h/n_h. offset = 0 is the fixed start that
    was actually used; a random offset in [0, k) is what a randomised-start
    design would have used."""
    idx = []
    for s, pos in groups.items():
        N, n = len(pos), nh.get(s)
        if not n:
            continue
        k = N / n
        j = np.arange(N)
        take = (((j - start_frac[s] * k) % k) < 1) & (np.floor((j - start_frac[s] * k) / k) < n)
        take &= (j >= start_frac[s] * k)
        idx.append(pos[take])
    return np.concatenate(idx)

# The sample is always used with its design weights, so the reference
# distribution is built from design-weighted means, matching how the estimates
# in this study are actually computed.
wmap = {s: len(pos) / nh[s] for s, pos in groups.items() if nh.get(s)}
ac_sorted["w"] = ac_sorted["stratum"].map(wmap)

stats = ["n_words", "depth", "caps_ratio", "score", "is_top_level"]
draws = {v: np.empty(B) for v in stats}
for b in range(B):
    sf = {s: rng.random() for s in groups}
    sub = ac_sorted.iloc[systematic(sf)]
    for v in stats:
        draws[v][b] = np.average(sub[v], weights=sub["w"])

fixed_idx = systematic({s: 0.0 for s in groups})
fixed = ac_sorted.iloc[fixed_idx]
print(f"\ncheck: fixed-start arm selects {len(fixed_idx)} comments "
      f"against an allocation of {int(sum(nh.values()))}")
rows = []
for v in stats:
    obs = np.average(fixed[v], weights=fixed["w"])
    pct = (draws[v] < obs).mean()
    rows.append(dict(statistic=v, fixed_start=round(obs, 4),
                     random_start_mean=round(draws[v].mean(), 4),
                     random_start_sd=round(draws[v].std(ddof=1), 4),
                     percentile=round(100 * pct, 1),
                     population=round(ac[v].mean(), 4)))
rnd = pd.DataFrame(rows)
rnd.to_csv(f"{ROOT}/output/tables/sampling_randomisation.csv", index=False)
print(f"\n\nRANDOMISATION REFERENCE: fixed start against {B} random-start draws\n")
print(rnd.to_string(index=False))
print(f"\nall percentiles inside [{rnd.percentile.min():.1f}, {rnd.percentile.max():.1f}]")
