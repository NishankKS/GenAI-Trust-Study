"""
S12b -- DESIGN-BASED PREVALENCE, RECOMPUTED

Recomputes the design-based supervised learning (DSL) prevalence estimates that
S12 produces. Two reasons this exists as a separate script:

  1. `arrow` is unavailable on the Linux build machine, so R/12_models.R cannot
     be re-run there; pandas/pyarrow read the same Parquet files.
  2. S12 formed the second-stage inclusion probability as
     nrow(gold) / nrow(samp) = 358 / 4997. The numerator counts the coded units
     that survived the frame correction while the denominator counts the full
     annotated sample including the units it removed. The human subsample was a
     simple random draw of 360 from 4,997, so the second-stage probability is
     360 / 4997; the mismatch made the correction term about 0.6% too large.

Only the DSL quantities are affected. The regression models use hard labels
(f > 0.5) and are untouched by the second-stage probability.

Usage:  python3 R/12b_dsl_prevalence.py [--legacy]
        --legacy reproduces the original 358/4997 figures, for verification.

Out: output/tables/prevalence_corrected.csv
     output/tables/by_subreddit.csv
     output/tables/rq1_dimension_target_corrected.csv
"""
import sys
import numpy as np
import pandas as pd

ROOT = "/home/nishanksatish/Documents/Final_R/R"
LEGACY = "--legacy" in sys.argv
rng = np.random.default_rng(20260901)

ac = pd.read_parquet(f"{ROOT}/data/parquet/analysis_corpus.parquet",
                     columns=["id", "subreddit", "created_utc"])
dp = pd.read_parquet(f"{ROOT}/data/derived/distilled_preds.parquet",
                     columns=["id", "p_relevant", "p_incivility", "p_trust", "p_distrust"])
dt = pd.read_parquet(f"{ROOT}/data/derived/distilled_preds_dimtarget.parquet")
samp = pd.read_parquet(f"{ROOT}/data/derived/annotation_sample.parquet",
                       columns=["id", "pi_h", "in_gold", "eligible", "stratum"])
gold = pd.read_csv(f"{ROOT}/data/derived/gold_labels.csv")

D = ac.merge(dp, on="id").merge(dt, on="id")
# ym is recomputed from the UTC timestamp, as in S12: the ingest label used
# local time and pushed a few late-August comments into a seventh month.
D["ym"] = pd.to_datetime(D["created_utc"], unit="s", utc=True).dt.strftime("%Y-%m")
D = D[D["ym"] <= "2026-08"].reset_index(drop=True)

# ---- attach human labels and their inclusion probabilities ------------------
G = gold.merge(samp[["id", "pi_h"]], on="id", how="inner")
n_gold_drawn = int(samp["in_gold"].sum())          # 360, the size of the SRS draw
n_annot = len(samp)                                # 4,997, the frame it was drawn from
p_gold = (len(gold) if LEGACY else n_gold_drawn) / n_annot
N_GOLD_ELIGIBLE = len(gold)                        # 358 coded units still in frame
N_ANNOT_ELIGIBLE = int(samp["eligible"].sum())     # 4,972 annotated units in frame

D["R"] = False
D["pi"] = np.nan
idx = D.index[D["id"].isin(set(G["id"]))]
gmap = G.set_index("id")
D.loc[idx, "pi"] = gmap.loc[D.loc[idx, "id"], "pi_h"].to_numpy() * p_gold
D.loc[idx, "R"] = True

y = {
    "relevant": (gmap["relevance"] == "relevant"),
    "distrust": (gmap["stance"] == "distrust"),
    "trust":    (gmap["stance"] == "trust"),
    "incivil":  (gmap["any_incivility"].astype(str).str.upper().isin(["TRUE", "1"])),
}
f_col = {"relevant": "p_relevant", "distrust": "p_distrust",
         "trust": "p_trust", "incivil": "p_incivility"}


# Which stage carries the randomisation, and therefore the variance.
#
#   theta_hat = (1/N) sum_pop f(X_i)  +  (1/N) sum_{i in R} (Y_i - f(X_i)) / pi_i
#
# The first term averages the classifier over EVERY comment in the corpus, so it
# has no sampling error. All variability sits in the second term, and enters
# through which comments are in R. Stage one (systematic selection into the
# annotated sample) is deterministic once the frame order is fixed; stage two
# (the draw of 360 of those 4,997 comments into the human-coded set) is simple
# random sampling. Resampling the coded units independently and with replacement
# is therefore the design-consistent bootstrap: it reproduces the one stage that
# actually randomises. Stratifying the resample would impose a structure the
# gold draw did not use and would understate the variance; that variant is
# computed below only to show the size of the difference.
FPC = np.sqrt(1 - N_GOLD_ELIGIBLE / N_ANNOT_ELIGIBLE)   # finite population


def dsl_estimate(f, yv, pi, strata=None, B=2000):
    """Naive mean, DSL-corrected mean, a bootstrap interval over the human-coded
    units, and the analytic standard error implied by the second-stage design."""
    naive = float(f.mean())
    e = (yv - f[idx].to_numpy()) / pi          # per-unit design-weighted error
    m, N = len(e), len(f)
    corrected = naive + e.sum() / N

    boot = np.empty(B)
    for b in range(B):
        boot[b] = naive + e[rng.integers(0, m, m)].sum() / N
    lo, hi = np.quantile(boot, [.025, .975])

    # analytic SRS standard error of the correction term, with the finite
    # population correction; agreement with the bootstrap SD verifies the latter
    se_analytic = np.sqrt(m * e.var(ddof=1)) / N * FPC

    se_strat = np.nan
    if strata is not None:
        bs = np.empty(B)
        groups = [np.where(strata == g)[0] for g in np.unique(strata)]
        for b in range(B):
            tot = 0.0
            for gi in groups:
                tot += e[gi[rng.integers(0, len(gi), len(gi))]].sum()
            bs[b] = naive + tot / N
        se_strat = bs.std(ddof=1)

    return dict(naive=naive, corrected=corrected, ci_low=float(lo), ci_high=float(hi),
                se_boot=float(boot.std(ddof=1)), se_analytic=float(se_analytic),
                se_stratified=float(se_strat))


pi_g = D.loc[idx, "pi"].to_numpy()
strata_g = gmap.join(samp.set_index("id")["stratum"]).loc[D.loc[idx, "id"], "stratum"].to_numpy()
rows, diag = [], []
for name, col in f_col.items():
    f = D[col]
    yv = y[name].loc[D.loc[idx, "id"]].to_numpy().astype(float)
    r = dsl_estimate(f, yv, pi_g, strata=strata_g)
    rows.append(dict(quantity=name, naive=round(r["naive"], 4),
                     corrected=round(r["corrected"], 4), ci_low=round(r["ci_low"], 4),
                     ci_high=round(r["ci_high"], 4),
                     shift_pp=round(100 * (r["corrected"] - r["naive"]), 2)))
    diag.append(dict(quantity=name, se_bootstrap=round(r["se_boot"], 4),
                     se_analytic=round(r["se_analytic"], 4),
                     ratio=round(r["se_boot"] / r["se_analytic"], 3),
                     se_stratified=round(r["se_stratified"], 4)))
prev = pd.DataFrame(rows)
print(prev.to_string(index=False))
dg = pd.DataFrame(diag)
if not LEGACY:
    dg.to_csv(f"{ROOT}/output/tables/dsl_variance_check.csv", index=False)
print("\nvariance check: bootstrap against the analytic second-stage design\n")
print(dg.to_string(index=False))

# ---- stance and incivility by venue ----------------------------------------
D["t_distrust"] = D["p_distrust"]
D["t_incivil"] = D["p_incivility"]
for tcol, ycol, fcol in (("t_distrust", "distrust", "p_distrust"),
                         ("t_incivil", "incivil", "p_incivility")):
    yv = y[ycol].loc[D.loc[idx, "id"]].to_numpy().astype(float)
    D.loc[idx, tcol] = D.loc[idx, fcol].to_numpy() + (yv - D.loc[idx, fcol].to_numpy()) / pi_g

by = (D.groupby("subreddit")
        .agg(n=("id", "size"), distrust=("p_distrust", "mean"), trust=("p_trust", "mean"),
             incivil=("p_incivility", "mean"), distrust_corr=("t_distrust", "mean"),
             incivil_corr=("t_incivil", "mean"))
        .reset_index())
print(by.round(4).to_string(index=False))

# ---- trust dimension and target --------------------------------------------
dim_cats = ["competence_reliability", "integrity_motives", "safety_risk",
            "transparency", "societal_impact", "not_applicable"]
tgt_cats = ["specific_model", "company", "technology_general",
            "community_users", "not_applicable"]
dt_rows = []
for kind, cats, goldcol in (("dimension", dim_cats, "dimension"),
                            ("target", tgt_cats, "target")):
    for c in cats:
        f = D[f"p_{kind}_{c}"]
        yv = (gmap[goldcol].loc[D.loc[idx, "id"]] == c).to_numpy().astype(float)
        r = dsl_estimate(f, yv, pi_g)
        dt_rows.append(dict(category_type=kind, category=c, naive=round(r["naive"], 4),
                            corrected=round(r["corrected"], 4),
                            ci_low=round(r["ci_low"], 4), ci_high=round(r["ci_high"], 4),
                            shift_pp=round(100 * (r["corrected"] - r["naive"]), 2)))
dtab = pd.DataFrame(dt_rows)
# share among comments where the field applies at all
dtab["corrected_share_of_evaluative"] = np.nan
for kind in ("dimension", "target"):
    m = (dtab.category_type == kind) & (dtab.category != "not_applicable")
    dtab.loc[m, "corrected_share_of_evaluative"] = (
        dtab.loc[m, "corrected"] / dtab.loc[m, "corrected"].sum()).round(4)
print(dtab.to_string(index=False))

if not LEGACY:
    prev.to_csv(f"{ROOT}/output/tables/prevalence_corrected.csv", index=False)
    by.to_csv(f"{ROOT}/output/tables/by_subreddit.csv", index=False)
    dtab.to_csv(f"{ROOT}/output/tables/rq1_dimension_target_corrected.csv", index=False)
    print("\nwritten: prevalence_corrected.csv, by_subreddit.csv, "
          "rq1_dimension_target_corrected.csv")
else:
    print("\n[legacy mode] nothing written")
