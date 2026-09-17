"""
S13b -- KNOWLEDGE GRAPH GROUNDEDNESS CHECK

The 100-triple manual verification sample has not been coded, so extraction
precision in the semantic sense is unknown and no precision figure is claimed.
What CAN be checked automatically is groundedness: whether the entities a triple
names actually occur in the comment it was extracted from. A triple whose
subject and object are both present in the source text may still misread the
relation, so this is an upper bound on precision rather than an estimate of it.
A triple whose endpoints do not appear at all is very likely an extraction
error, so the check is informative in one direction.

Matching is deliberately generous: case-insensitive, punctuation-stripped, and
satisfied when any content token of the entity of three or more characters
appears in the comment, with the canonical alias list applied so that "ChatGPT"
counts as present when the comment says "gpt" or "4o".

Out: output/tables/kg_groundedness.csv
"""
import glob
import re
import numpy as np
import pandas as pd

ROOT = "/home/nishanksatish/Documents/Final_R/R"

ALIAS = {
    "chatgpt": ["chatgpt", "chat gpt", "gpt", "4o", "openai's model"],
    "openai": ["openai", "open ai"],
    "claude": ["claude"],
    "gemini": ["gemini", "bard"],
    "google": ["google", "alphabet", "deepmind"],
    "anthropic": ["anthropic"],
    "grok": ["grok"],
    "deepseek": ["deepseek", "deep seek"],
    "ai (general)": ["ai", "a.i.", "artificial intelligence", "llm", "llms",
                     "generative ai", "genai", "large language model"],
}
STOP = {"the", "and", "for", "with", "of", "a", "an", "to", "in", "on", "its"}


def norm(t):
    return re.sub(r"[^a-z0-9 ]+", " ", str(t).lower())


def present(entity, text):
    e, t = norm(entity), norm(text)
    for a in ALIAS.get(entity.strip().lower(), []):
        if re.search(rf"\b{re.escape(a)}\b", t):
            return True
    toks = [w for w in e.split() if len(w) >= 3 and w not in STOP]
    if not toks:
        toks = [w for w in e.split() if w]
    return any(re.search(rf"\b{re.escape(w)}", t) for w in toks)


# source texts for the sampled comments
samp = pd.read_csv(f"{ROOT}/data/derived/annotation_sample.csv",
                   usecols=["id", "text"], na_filter=False)
text = dict(zip(samp["id"], samp["text"]))

ps = pd.read_csv(f"{ROOT}/output/tables/kg_precision_sample.csv", na_filter=False)
ps = ps[ps["comment_id"].isin(text)]
ps["subject_found"] = [present(s, text[c]) for s, c in zip(ps["subject"], ps["comment_id"])]
ps["object_found"] = [present(o, text[c]) for o, c in zip(ps["object"], ps["comment_id"])]
ps["both_found"] = ps["subject_found"] & ps["object_found"]

out = pd.DataFrame([
    dict(check="subject present in source comment",
         n=len(ps), share=round(ps["subject_found"].mean(), 3)),
    dict(check="object present in source comment",
         n=len(ps), share=round(ps["object_found"].mean(), 3)),
    dict(check="both endpoints present (groundedness)",
         n=len(ps), share=round(ps["both_found"].mean(), 3)),
])
out.to_csv(f"{ROOT}/output/tables/kg_groundedness.csv", index=False)
print(f"groundedness of the {len(ps)} sampled triples "
      f"(automatic lexical check, not a precision estimate)\n")
print(out.to_string(index=False))
print("\nvalence distribution of the sampled triples:")
print(ps["valence"].value_counts().to_string())
print("\nexamples where an endpoint was not located in the source comment:")
bad = ps[~ps["both_found"]][["comment_id", "subject", "relation", "object"]].head(5)
print(bad.to_string(index=False) if len(bad) else "  none")
