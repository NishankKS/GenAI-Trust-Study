# Submission_Final — Trust, Incivility and Public Perceptions of Generative AI

Built from the **45-page `seminar_report.pdf`/`.tex`** in the repository root (not
the earlier 18-page draft in `submission/`). The original repository was not
modified; this folder is self-contained.

## Files

| File | Deliverable |
|---|---|
| `seminar_report_final.qmd` | Source. One file, content + code + plots. |
| `seminar_report_final.pdf` | **PDF without code** — the graded version (24 pp: 1 cover, 20 body, 3 refs, 1 declaration). |
| `supplementary/seminar_report_final_withcode.html` | **HTML with code** — rendered with `-M echo:true -M output:true`. |
| `supplementary/seminar_report_final_nocode.html` | **HTML without code** — rendered with default `echo: false` / `output: false`. |
| `references.bib`, `apa.csl` | Bibliography (36 entries, all cited, none orphaned) and APA7 style. |
| `output/`, `coding/`, `data/derived/` | The subset of project outputs the code chunks actually read (figures, tables, gold labels, coder sheets). Full raw data is in the repository root and `submission/`. |

## Rendering

```
export R_LIBS=<path to project renv library>
quarto render seminar_report_final.qmd --to pdf                              # deliverable 1
quarto render seminar_report_final.qmd --to html                             # deliverable 3 (no code)
quarto render seminar_report_final.qmd --to html -M echo:true -M output:true # deliverable 2 (with code)
```

The four "real executable" chunks (`alpha-real`, `score-real`, `dsl-real`,
`chisq-real`) carry `#| output: false` as their default, matching the
document's `echo: false` default — this hides both their source *and* their
printed return value in the PDF and the no-code HTML (a raw R console dump of
a `data.table` or `sprintf` string is not something a reader should see next
to formatted prose). The `-M output:true` flag flips that default alongside
`-M echo:true`, so the with-code HTML shows both the source and the executed
result — proof, not just an assertion, that the chunk reproduces the number
quoted in the text.

The four required files (`.qmd` + the used dataset as `.zip`) still need the
dataset packaged — not done in this pass; see the `.qmd` for exactly which files
under `output/`, `coding/`, `data/derived/` are read.

## Page count vs. target

| Section | Pages | Target |
|---|---|---|
| Introduction | 1 | ~1 |
| Theoretical Background + RQ | 2 | ~2 |
| Methodological Approach | 6 | ≤7 |
| Results | 7 | ≤7 |
| Discussion | 2 | ~3 |
| Critical Reflection/Limitations/Outlook/Conclusion | 1 | (not separately budgeted) |
| **Body total** | **20** | **18–20** |
| References | 3 | — |
| Eidesstattliche Erklärung | 1 | — |
| **Grand total** | **24** | — |

Introduction is the original's wording verbatim (only `\rc{}{}` citation macros
converted to `[@key]` and `Section~\ref{}` converted to plain section numbers).
Discussion sits at 2 pages against a ~3-page guideline — condensed from the
source's 3-page version by roughly 30% to make room within the ≤7+≤7 ceiling on
Method/Results; if a more expansive Discussion is preferred, there is room to
add up to a page before the 18–20 body budget is exceeded.

## Code chunks: what is real, what is illustrative

Per the "option B" instruction, four chunks are genuinely executed against data
shipped in this folder (verified independently before being written into the
report — each reproduces the exact number quoted in the 45-page source):

| Chunk | What it does | Reproduces |
|---|---|---|
| `alpha-real` | Krippendorff's alpha, computed from scratch | α = 0.907 / 0.872 / 0.769 |
| `score-real` | Macro-F1 scoring function | macro F1 = 0.611, accuracy = 0.713 |
| `dsl-real` | The design-based correction function, toy-tested | shows the mechanism, not the full corpus run |
| `chisq-real` | Chi-square / Cramér's V | χ² = 7934.5, V = 0.179 |

Three chunks are marked `eval: false` — the actual lines from the project's own
scripts (`R/10_distill.R`, `R/11_topics.R`, `R/12_models.R`), shown for
transparency but not executed, because they require `glmnet`-on-embeddings,
`seededlda`, or `glmmTMB`, none of which are installed in this rendering
environment, or depend on the external Groq/Claude annotation API. This is
disclosed inline in the surrounding prose, not hidden.

All table/figure chunks read pre-computed CSVs and PNGs from `output/tables/`
and `output/figures/report/` — the same outputs the 45-page source report
itself was built from.

## What moved to supplementary material

Detailed treatment of the following is condensed to one or two sentences with a
pointer to "Supplementary Analysis Sx" in the text, matching the numbering used
in `submission/supplementary/` from the prior packaging stage:

- S1 sampling balance/randomisation diagnostics
- S2 full reliability + validation + inter-model tables (13 instrument rows)
- S3 DSL bootstrap-vs-analytic variance check
- S4 dimension/target full breakdown
- S6 reply-level cascade model detail
- S7 calibration + moderator-removal bound detail
- S9 full knowledge-graph structure (edge types, entity table, network figure)

None of this content was deleted from the project — it exists in full in
`submission/supplementary/analyses/supplementary_analyses.pdf` from the prior
stage, produced from the same `output/tables/` this report reads.

## Known issues

1. **Eidesstattliche Erklärung is unsigned.** Blank signature rules for both
   authors, dated 13.09.2026. A typed name is not sufficient per course
   requirements — this must be hand-signed before submission.
2. **HTML-with-code is produced via render-time flags** (`-M echo:true -M
   output:true`), not a second qmd file, so there is exactly one source of
   truth. Re-running the plain `quarto render ... --to html` without the flags
   reproduces the no-code HTML.
3. **Dataset zip packaging** (the fourth Session-11 deliverable) is not done in
   this pass — only the report and its three renders were requested this turn.
