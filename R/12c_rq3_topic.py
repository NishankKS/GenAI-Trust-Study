"""
S12c -- RQ3, TOPIC COMPONENT

RQ3 asks how uncivil communication differs across AI-related topics AND across
trust categories. The multilevel model in S12 answers the trust-category half.
It cannot answer the topic half, because topic labels exist only for the
comments the topic model retains (246,705 of 824,518), so adding topic as a
predictor would silently change the estimation sample.

The topic half is therefore answered descriptively, on the topic-labelled
subset, with a chi-square test of independence and Cramer's V as an effect size,
since significance at this n is trivially attainable and uninformative on its
own. Labels are classifier output and are not error-corrected, so these are
associations in the predicted labels.

Out: output/tables/rq3_topic.csv, output/tables/rq3_topic_tests.csv
"""
import numpy as np
import pandas as pd
from scipy import stats

ROOT = "/home/nishanksatish/Documents/Final_R/R"

dp = pd.read_parquet(f"{ROOT}/data/derived/distilled_preds.parquet",
                     columns=["id", "p_incivility", "pred_stance"])
tp = pd.read_parquet(f"{ROOT}/data/derived/topics_seeded.parquet")
D = tp.merge(dp, on="id")
D["incivil"] = D["p_incivility"] > 0.5
D["stance3"] = np.where(D["pred_stance"].isin(["trust", "distrust", "ambivalent"]),
                        D["pred_stance"], "non_evaluative")

seeded = ["accuracy_hallucination", "art_copyright", "capability_quality",
          "companionship_use", "corporate_money", "education_cheating",
          "labour_displacement", "privacy_data", "regulation_policy",
          "safety_alignment"]
D["seeded"] = D["topic"].isin(seeded)

tab = (D.groupby("topic")
         .agg(n=("id", "size"), incivil=("incivil", "mean"),
              distrust=("stance3", lambda s: (s == "distrust").mean()),
              trust=("stance3", lambda s: (s == "trust").mean()))
         .reset_index())
tab["seeded"] = tab["topic"].isin(seeded)
tab = tab.sort_values("incivil", ascending=False).round(4)
tab.to_csv(f"{ROOT}/output/tables/rq3_topic.csv", index=False)
print(tab.to_string(index=False))


def cramers_v(ct):
    chi2, p, dof, _ = stats.chi2_contingency(ct, correction=False)
    n = ct.to_numpy().sum()
    v = np.sqrt(chi2 / (n * (min(ct.shape) - 1)))
    exp = stats.chi2_contingency(ct, correction=False)[3]
    cochran = (exp < 5).mean() <= 0.20 and exp.min() >= 1
    return chi2, dof, p, v, cochran


rows = []
for name, ct in (("topic x incivility", pd.crosstab(D["topic"], D["incivil"])),
                 ("stance x incivility", pd.crosstab(D["stance3"], D["incivil"])),
                 ("topic x stance", pd.crosstab(D["topic"], D["stance3"]))):
    chi2, dof, p, v, ok = cramers_v(ct)
    rows.append(dict(test=name, chi2=round(chi2, 1), df=dof,
                     p=p, cramers_v=round(v, 3), cochran_ok=bool(ok), n=int(ct.to_numpy().sum())))
tests = pd.DataFrame(rows)
tests.to_csv(f"{ROOT}/output/tables/rq3_topic_tests.csv", index=False)
print()
print(tests.to_string(index=False))
