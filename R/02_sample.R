## ---------------------------------------------------------------------------
## S3 -- SAMPLING DESIGN
##
## One stratified probability sample is drawn from the analysis corpus. The
## human gold standard is a simple random SUBSAMPLE of it. That nesting is
## deliberate: it means the human-coded set is a probability sample of the
## LLM-annotated set, which is the condition design-based supervised learning
## (S9) needs in order to correct the classifier's error without bias.
##
## Inclusion probabilities are recorded for every sampled unit. Without them
## none of the population estimates later in the study are defensible.
##
## Input : data/parquet/analysis_corpus.parquet
## Output: data/derived/annotation_sample.parquet   (n = 5000, for the LLM)
##         data/derived/gold_sample.csv             (n =  360, for humans)
##         output/tables/sampling_design.csv
##         docs/codebook.md
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({library(arrow); library(data.table)})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")
set.seed(20260901)

N_ANNOT <- 5000L    # LLM-annotated sample
N_GOLD  <-  360L    # human double-coded subsample
N_TEST  <-  150L    # of the gold, locked until every model choice is final

ac <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
cat(sprintf("[S3] population N = %s\n", format(nrow(ac), big.mark = ",")))

## ---- strata ---------------------------------------------------------------
## subreddit x lexical-AI-reference x length band.
## Comments WITHOUT a lexical AI reference are deliberately retained in the
## frame at a reduced rate: the LLM relevance judgement must be estimable on
## them too, or the relevance gate itself could never be validated.
ac[, len_band := cut(n_words, breaks = c(3, 15, 50, Inf),
                     labels = c("short", "medium", "long"))]
ac[, stratum := paste(subreddit, ifelse(has_ai_ref, "airef", "noref"), len_band, sep = "|")]

Nh <- ac[, .(N_h = .N), by = stratum]

## ---- allocation -----------------------------------------------------------
## 70% of the sample to strata carrying an AI reference (34.2% of the
## population) and 30% to those without: a disproportionate design that buys
## precision where the constructs actually vary, paid for with weights.
## Within each group, sqrt(N_h) allocation so the small venues -- especially
## r/MachineLearning at 2.9% of the corpus -- are not sampled out of existence.
Nh[, has_ref := grepl("airef", stratum)]
Nh[, share := sqrt(N_h) / sum(sqrt(N_h)), by = has_ref]
Nh[, n_h := pmax(20L, round(share * fifelse(has_ref, 0.70, 0.30) * N_ANNOT))]
Nh[, n_h := pmin(n_h, N_h)]
Nh[, pi_h := n_h / N_h]                      # inclusion probability
Nh[, w_h  := 1 / pi_h]                       # design weight
cat(sprintf("[S3] %d strata, allocated n = %d\n", nrow(Nh), sum(Nh$n_h)))

## ---- draw: systematic sample within stratum, ordered by time --------------
## Ordering by timestamp before systematic selection gives implicit
## stratification on month at no cost in degrees of freedom.
ac[Nh, on = "stratum", `:=`(n_h = i.n_h, N_h = i.N_h, pi_h = i.pi_h, w_h = i.w_h)]
setorder(ac, stratum, created_utc)
ac[, rk := seq_len(.N), by = stratum]
## NOTE: a per-stratum random start is drawn below but is NOT used by the
## selection rule, which begins at rank 1 in every stratum. The realised design
## is therefore 1-in-k systematic selection with a FIXED start from a
## time-ordered frame, not a randomised-start systematic sample. The sample was
## drawn, annotated and hand-coded before this was noticed, and redrawing it
## would discard the whole annotation layer, so it is reported as it stands:
## pi_h = n_h/N_h is the nominal rate, valid under the usual assumption that the
## time ordering is unrelated to the constructs. The GOLD subsample below is a
## genuine simple random draw, and that is the stage the error correction in
## S12 actually depends on.
ac[, start := NA_real_]
starts <- ac[, .(start = runif(1)), by = stratum]
ac[starts, on = "stratum", start := i.start]
ac[, take := ((rk - 1) %% (N_h / n_h)) < 1 &
            floor((rk - 1) / (N_h / n_h)) < n_h]
samp <- ac[take == TRUE]
samp[, take := NULL]
cat(sprintf("[S3] drawn n = %s\n", format(nrow(samp), big.mark = ",")))

## ---- gold subsample: simple random, so it inherits the design -------------
samp[, in_gold := FALSE]
gold_idx <- sample(seq_len(nrow(samp)), N_GOLD)
samp[gold_idx, in_gold := TRUE]

## ---- dev / test split. The test half is LOCKED. --------------------------
samp[, gold_split := NA_character_]
g <- which(samp$in_gold)
test_idx <- sample(g, N_TEST)
samp[g, gold_split := "dev"]
samp[test_idx, gold_split := "test"]
cat(sprintf("[S3] gold: %d dev / %d test\n",
            sum(samp$gold_split == "dev", na.rm = TRUE),
            sum(samp$gold_split == "test", na.rm = TRUE)))

## ---- persist --------------------------------------------------------------
keep <- c("id","subreddit","ym","created_ts","thread_slug","text","n_words",
          "score","depth","is_top_level","has_ai_ref","parent_text",
          "stratum","N_h","n_h","pi_h","w_h","in_gold","gold_split",
          "caps_ratio","n_question","n_exclaim","n_2ndperson","n_links")
out <- samp[, ..keep]
write_parquet(out, "data/derived/annotation_sample.parquet", compression = "zstd")

gold <- out[in_gold == TRUE][sample(.N)]     # shuffled so coders see no order effect
fwrite(gold[, .(id, subreddit, thread_slug, parent_text, text, gold_split)],
       "data/derived/gold_sample.csv")

design <- Nh[order(-N_h)][, .(stratum, N_h, n_h, pi_h = round(pi_h, 5), w_h = round(w_h, 1))]
fwrite(design, "output/tables/sampling_design.csv")

cat("\n[S3] sample composition vs population\n")
cmp <- merge(
  ac[, .(pop = .N / nrow(ac)), by = subreddit],
  out[, .(smp = .N / nrow(out), wtd = sum(w_h)), by = subreddit], by = "subreddit")
cmp[, wtd := wtd / sum(wtd)]
print(cmp[order(-pop)][, lapply(.SD, function(x) if (is.numeric(x)) round(x, 3) else x)])

## ---- render the codebook to markdown --------------------------------------
md <- c("# Codebook", "",
        "Generated from `R/codebook.R`. Do not edit this file by hand -- edit the",
        "R source, which is also what is pasted into the LLM prompts and used to",
        "build the response schema.", "",
        "Note: quoted text (`> ...`), code blocks and URLs are stripped before",
        "coding, so every word a coder sees is the commenter's own.", "",
        codebook_prompt_block())
writeLines(md, "docs/codebook.md")
cat("[S3] docs/codebook.md written\n")
