## ---------------------------------------------------------------------------
## S11 -- TOPIC STRUCTURE (RQ2), TWO WAYS
##
## One topic model is a guess. Two models built on different principles, that
## converge on the same structure, is evidence. This script fits the
## theory-driven half and cross-tabulates it against the data-driven half
## produced by R/11b_topics_embed.py.
##
##   THEORY-DRIVEN   seeded LDA (Watanabe & Zhou). Ten topics seeded with terms
##                   derived from the literature on public AI discourse, plus
##                   residual topics that absorb whatever the theory missed.
##                   Semi-supervised, so the topics are interpretable and their
##                   identity is fixed in advance rather than read off the output.
##
##   DATA-DRIVEN     HDBSCAN over sentence embeddings with c-TF-IDF keywords,
##                   which can find themes the seed list never anticipated.
##
## Choosing K by eyeballing top words is the standard weakness of student topic
## models. Here K is fixed by theory for the seeded model, and the two solutions
## are checked against each other with an alignment matrix.
##
## Out: data/derived/topics_seeded.parquet
##      output/tables/topic_terms.csv, topic_prevalence.csv,
##      topic_by_stance.csv, topic_alignment.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(quanteda); library(seededlda)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
quanteda_options(threads = 6)
set.seed(20260901)

## Fit on every relevant document rather than a subsample. seededlda's
## out-of-sample predict() is defunct, and fitting the whole set avoids needing
## it at all -- at this corpus size it costs minutes, not hours.
MAX_FIT <- Inf

## ---- the seed dictionary ---------------------------------------------------
## Derived from the literature on public perceptions of AI, not from inspecting
## this corpus, so the topics are hypotheses rather than post-hoc descriptions.
seeds <- dictionary(list(
  labour_displacement = c("job*", "career*", "employ*", "hiring", "layoff*", "unemploy*",
                          "replac*", "worker*", "salary", "junior", "workforce"),
  accuracy_hallucination = c("hallucinat*", "wrong", "false", "accura*", "factual", "cite",
                             "citation*", "misinform*", "made up", "incorrect", "reliab*"),
  privacy_data = c("privacy", "private", "personal data", "tracking", "surveillance",
                   "consent", "gdpr", "leak*", "confidential"),
  safety_alignment = c("safety", "safe", "harm*", "danger*", "risk*", "alignment",
                       "guardrail*", "jailbreak*", "censor*", "minor*", "suicide", "therapy"),
  capability_quality = c("better", "worse", "quality", "capab*", "benchmark*", "performance",
                         "upgrade*", "downgrade*", "smarter", "dumber", "nerf*", "context window"),
  regulation_policy = c("regulat*", "law*", "legal", "government", "policy", "ban*",
                        "lawsuit*", "court", "antitrust", "legislat*"),
  art_copyright = c("art", "artist*", "copyright", "stolen", "training data", "creative",
                    "style", "slop", "plagiar*", "royalt*"),
  education_cheating = c("school*", "student*", "teacher*", "homework", "essay*", "cheat*",
                         "exam*", "universit*", "assignment*", "grading"),
  corporate_money = c("openai", "altman", "anthropic", "google", "microsoft", "profit*",
                      "subscription", "pric*", "revenue", "valuation", "enshittif*", "paywall"),
  companionship_use = c("friend*", "companion*", "lonely", "loneliness", "relationship*",
                        "emotional", "girlfriend", "parasocial", "attached", "comfort")
))

## ---- corpus ----------------------------------------------------------------
ac <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
dp <- if (file.exists("data/derived/distilled_preds.parquet"))
        as.data.table(read_parquet("data/derived/distilled_preds.parquet")) else NULL
if (!is.null(dp)) ac[dp, on = "id", `:=`(pred_relevance = i.pred_relevance,
                                         pred_stance = i.pred_stance)]

## Topics are modelled on the comments that actually discuss AI. Using the whole
## corpus would let the image-meme threads dominate the solution, which is
## exactly the failure mode the relevance gate exists to prevent.
sub <- if (!is.null(dp)) ac[pred_relevance == "relevant"] else ac[has_ai_ref == TRUE]
cat(sprintf("[S11] topic corpus: %s comments (%s)\n", format(nrow(sub), big.mark = ","),
            if (!is.null(dp)) "distilled relevance" else "lexical prefilter"))

crp <- corpus(sub$text, docnames = sub$id)
tk  <- tokens(crp, remove_punct = TRUE, remove_numbers = TRUE, remove_symbols = TRUE,
              remove_url = TRUE) |>
       tokens_tolower() |>
       tokens_remove(c(stopwords("en"), "just", "like", "get", "one", "really", "also",
                       "even", "much", "well", "make", "think", "know", "people", "use",
                       "using", "used", "thing", "things", "way", "lot", "s", "t", "m",
                       ## Reddit text carries typographic apostrophes, which the
                       ## English stopword list (written with ASCII ones) misses
                       "it's", "don't", "i'm", "that's", "you're", "i've",
                       "doesn't", "can't", "didn't", "isn't", "they're",
                       "’s", "’t", "’re", "’ve", "’m")) |>
       tokens_ngrams(n = 1:2, concatenator = " ")
## docfreq_type applies to both bounds at once, so the count-based floor and the
## proportion-based ceiling have to be applied in two passes.
dfmat <- dfm(tk) |>
  dfm_trim(min_termfreq = 20, min_docfreq = 10, docfreq_type = "count") |>
  dfm_trim(max_docfreq = 0.4, docfreq_type = "prop")
dfmat <- dfm_subset(dfmat, ntoken(dfmat) >= 3)
cat(sprintf("[S11] dfm %s docs x %s features\n",
            format(ndoc(dfmat), big.mark = ","), format(nfeat(dfmat), big.mark = ",")))

fit_dfm <- if (ndoc(dfmat) > MAX_FIT) dfm_sample(dfmat, MAX_FIT) else dfmat
cat(sprintf("[S11] fitting seeded LDA on %s docs\n", format(ndoc(fit_dfm), big.mark = ",")))

t0 <- Sys.time()
lda <- textmodel_seededlda(fit_dfm, seeds, residual = 4, batch_size = 0.05,
                           auto_iter = TRUE, verbose = FALSE)
cat(sprintf("[S11] fitted in %.1f min\n", as.numeric(difftime(Sys.time(), t0, units = "mins"))))

terms_tab <- as.data.table(terms(lda, 15), keep.rownames = FALSE)
fwrite(terms_tab, "output/tables/topic_terms.csv")
cat("\n[S11] topic terms\n"); print(terms_tab[1:8])

## ---- assign every document -------------------------------------------------
## The model was fitted on the full dfm, so topic assignments come straight off
## it; no out-of-sample inference is required.
tp <- topics(lda)
topics_dt <- data.table(id = names(tp), topic = as.character(tp))
write_parquet(topics_dt, "data/derived/topics_seeded.parquet", compression = "zstd")

sub2 <- merge(sub, topics_dt, by = "id")
prev <- sub2[, .(n = .N), by = topic][, share := n / sum(n)][order(-n)]
fwrite(prev, "output/tables/topic_prevalence.csv")
cat("\n[S11] topic prevalence\n"); print(prev)

## by month, for the time series
bym <- sub2[, .N, by = .(ym, topic)][, share := N / sum(N), by = ym][order(ym, -share)]
fwrite(bym, "output/tables/topic_by_month.csv")

## by subreddit
bysub <- sub2[, .N, by = .(subreddit, topic)][, share := N / sum(N), by = subreddit]
fwrite(bysub, "output/tables/topic_by_subreddit.csv")

## ---- topic x stance --------------------------------------------------------
## The single most informative table in the paper: which themes are the
## distrusting ones.
if ("pred_stance" %in% names(sub2)) {
  ts <- sub2[!is.na(pred_stance), .N, by = .(topic, pred_stance)]
  ts[, share := N / sum(N), by = topic]
  w <- dcast(ts, topic ~ pred_stance, value.var = "share", fill = 0)
  num <- setdiff(names(w), "topic")
  w[, (num) := lapply(.SD, function(x) round(x, 3)), .SDcols = num]
  if (all(c("trust", "distrust") %in% names(w)))
    w[, distrust_ratio := round(distrust / pmax(trust, .001), 2)]
  setorder(w, -distrust)
  fwrite(w, "output/tables/topic_by_stance.csv")
  cat("\n[S11] topic x stance\n"); print(w)
}

## ---- alignment with the data-driven solution --------------------------------
ef <- "data/derived/topics_embedding.parquet"
if (file.exists(ef)) {
  et <- as.data.table(read_parquet(ef))
  al <- merge(topics_dt, et[, .(id, cluster = as.character(cluster))], by = "id")
  am <- dcast(al[, .N, by = .(topic, cluster)], topic ~ cluster, value.var = "N", fill = 0)
  fwrite(am, "output/tables/topic_alignment.csv")
  ## normalised mutual information between the two partitions
  tb <- table(al$topic, al$cluster); p <- tb / sum(tb)
  px <- rowSums(p); py <- colSums(p)
  mi <- sum(ifelse(p > 0, p * log(p / outer(px, py)), 0))
  nmi <- mi / sqrt(-sum(px * log(px)) * -sum(py * log(py)))
  cat(sprintf("\n[S11] seeded vs embedding solution: NMI = %.3f over %s shared docs\n",
              nmi, format(nrow(al), big.mark = ",")))
  writeLines(sprintf("NMI = %.4f (n = %d)", nmi, nrow(al)),
             "output/tables/topic_alignment_nmi.txt")
} else {
  cat("\n[S11] embedding topics not present yet -- run R/11b_topics_embed.py, then rerun\n")
}
