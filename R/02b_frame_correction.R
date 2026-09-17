## ---------------------------------------------------------------------------
## S3c -- FRAME CORRECTION
##
## Analysis of the topic clusters surfaced a class of comment that should never
## have been in the sampling frame: official moderation. `ChatGPT-ModTeam` alone
## posts 2,635 removal notices, and those notices quote the rule being enforced
## ("abusive/offensive language is not allowed"), which would have contaminated
## the incivility measure specifically. R/01_corpus.R now excludes them.
##
## The sample was already drawn and 360 of its comments already hand-coded, so
## the frame is NOT resampled. Instead this is handled the way a survey handles
## a sampled unit later found to be out of scope:
##
##   1. sampled units that are no longer in the frame are marked INELIGIBLE and
##      dropped from estimation (24 of 4,997; 2 of the 360 coded);
##   2. stratum sizes N_h are recomputed against the corrected frame, and the
##      inclusion probabilities and design weights are updated accordingly.
##
## The correction is small (0.33% of the corpus) but it is recorded rather than
## quietly absorbed, because the weights depend on N_h.
##
## Out: data/derived/annotation_sample.parquet  (updated in place)
##      output/tables/frame_correction.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({library(arrow); library(data.table)})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)

ac   <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))

## the stratum definition must match R/02_sample.R exactly
ac[, len_band := cut(n_words, breaks = c(3, 15, 50, Inf),
                     labels = c("short", "medium", "long"))]
ac[, stratum := paste(subreddit, ifelse(has_ai_ref, "airef", "noref"), len_band, sep = "|")]

before_n   <- nrow(samp)
samp[, eligible := id %in% ac$id]
n_inelig   <- sum(!samp$eligible)
n_gold_bad <- samp[in_gold == TRUE & !eligible, .N]

## recompute stratum sizes against the corrected frame
Nh_new <- ac[, .(N_h_new = .N), by = stratum]
samp[Nh_new, on = "stratum", N_h_new := i.N_h_new]
samp[, `:=`(N_h_old = N_h, pi_h_old = pi_h)]
samp[!is.na(N_h_new), `:=`(N_h = N_h_new, pi_h = n_h / N_h_new, w_h = N_h_new / n_h)]
samp[, N_h_new := NULL]

write_parquet(samp, "data/derived/annotation_sample.parquet", compression = "zstd")

rep <- data.table(
  quantity = c("frame before correction", "frame after correction",
               "comments removed (official moderation)",
               "sampled units", "sampled units now ineligible",
               "hand-coded units", "hand-coded units now ineligible",
               "mean design weight before", "mean design weight after"),
  value = c(827233, nrow(ac), 827233 - nrow(ac),
            before_n, n_inelig,
            samp[in_gold == TRUE, .N], n_gold_bad,
            round(mean(samp$N_h_old / samp$n_h), 2),
            round(mean(samp$w_h), 2)))
fwrite(rep, "output/tables/frame_correction.csv")
print(rep)

cat(sprintf("\n[S3c] %d of %d sampled units ineligible (%.2f%%); %d of the coded set\n",
            n_inelig, before_n, 100 * n_inelig / before_n, n_gold_bad))
cat(sprintf("[S3c] design weights shifted by %.3f%% on average\n",
            100 * mean(abs(samp$w_h - samp$N_h_old / samp$n_h)) /
              mean(samp$N_h_old / samp$n_h)))
cat("[S3c] the drawn sample is NOT redrawn -- ineligible units are dropped, as in survey practice\n")
