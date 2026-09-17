## ---------------------------------------------------------------------------
## S12 -- ESTIMATION, AND THE CORRECTION THAT MAKES IT VALID
##
## Every quantity below is computed from classifier output, so every quantity
## below is biased if taken at face value. A classifier at F1 = .8 does not
## produce "the prevalence of distrust"; it produces a number that differs from
## it by an amount that depends on the classifier's error profile, wrapped in a
## confidence interval that is far too narrow because it ignores that error.
##
## The fix is design-based supervised learning (Egami, Hinck, Stewart & Wei).
## Because the human-coded set is a PROBABILITY SUBSAMPLE of the annotated set
## with known inclusion probabilities (see R/02_sample.R), we can form the
## doubly-robust pseudo-outcome
##
##     Y~_i  =  f(X_i)  +  (R_i / pi_i) * (Y_i - f(X_i))
##
## where f() is the classifier, R_i marks a human-coded unit and pi_i is its
## inclusion probability. E[Y~] = E[Y] regardless of how bad f() is: the
## classifier only affects the VARIANCE, never the bias. Estimates run on Y~
## are therefore consistent, and the intervals are honest.
##
## Naive estimates are reported alongside throughout. The gap between them is
## itself a result worth a paragraph.
##
## Out: output/tables/prevalence_corrected.csv, model_incivility.csv,
##      model_cascade.csv, timeseries.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(glmmTMB)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
set.seed(20260901)

ac   <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
dp   <- as.data.table(read_parquet("data/derived/distilled_preds.parquet"))
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
gold <- fread("data/derived/gold_labels.csv")
tp   <- if (file.exists("data/derived/topics_seeded.parquet"))
          as.data.table(read_parquet("data/derived/topics_seeded.parquet")) else NULL

D <- merge(ac, dp, by = "id")
## The ym label was derived with strftime at ingest, which formats in local time
## and pushed a few late-August UTC comments into a seventh month. The window
## was closed at 31 August, so ym is recomputed from the UTC timestamp here.
D[, ym := format(as.POSIXct(created_utc, origin = "1970-01-01", tz = "UTC"), "%Y-%m")]
D <- D[ym <= "2026-08"]
if (!is.null(tp)) D <- merge(D, tp, by = "id", all.x = TRUE)
cat(sprintf("[S12] analysis frame: %s comments\n", format(nrow(D), big.mark = ",")))

## ---- attach the human labels and their inclusion probabilities -------------
D[, `:=`(R = FALSE, pi = NA_real_,
         y_relevant = NA, y_distrust = NA, y_trust = NA, y_incivil = NA)]
G <- merge(gold, samp[, .(id, pi_h)], by = "id")
D[G, on = "id", `:=`(
  R = TRUE, pi = i.pi_h,
  y_relevant = i.relevance == "relevant",
  y_distrust = i.stance == "distrust",
  y_trust    = i.stance == "trust",
  y_incivil  = i.any_incivility)]
## pi_h is the probability of entering the ANNOTATED sample; the human subsample
## was drawn from it by simple random sampling, so the two stages multiply.
## The numerator is the SIZE OF THE DRAW (360), not the number of coded units
## that survived the frame correction (358). Simple random selection does not
## depend on eligibility, so every unit in the annotated sample faced the same
## second-stage probability 360/4997; mixing the surviving count with the full
## denominator understates pi and inflates the correction term.
p_gold <- sum(samp$in_gold) / nrow(samp)
D[R == TRUE, pi := pi * p_gold]
cat(sprintf("[S12] %d human-coded units carry inclusion probabilities\n", sum(D$R)))

## ---- DSL pseudo-outcomes ----------------------------------------------------
dsl <- function(f_hat, y, R, pi) {
  y <- as.numeric(y); f_hat <- as.numeric(f_hat)
  out <- f_hat
  i <- which(R & !is.na(y))
  out[i] <- f_hat[i] + (y[i] - f_hat[i]) / pi[i]
  out
}
D[, f_relevant := p_relevant]
D[, f_distrust := if ("p_distrust" %in% names(D)) p_distrust else as.numeric(pred_stance == "distrust")]
D[, f_trust    := if ("p_trust"    %in% names(D)) p_trust    else as.numeric(pred_stance == "trust")]
D[, f_incivil  := p_incivility]

D[, `:=`(t_relevant = dsl(f_relevant, y_relevant, R, pi),
         t_distrust = dsl(f_distrust, y_distrust, R, pi),
         t_trust    = dsl(f_trust,    y_trust,    R, pi),
         t_incivil  = dsl(f_incivil,  y_incivil,  R, pi))]

## ---- RQ1: prevalence, naive vs corrected -----------------------------------
## Bootstrap over the human-coded units, which is where the correction's
## variance lives.
boot_dsl <- function(f_hat, y, R, pi, B = 400) {
  idx_R <- which(R & !is.na(y))
  est <- numeric(B)
  for (b in seq_len(B)) {
    s <- sample(idx_R, length(idx_R), replace = TRUE)
    adj <- mean(f_hat) + sum((as.numeric(y[s]) - f_hat[s]) / pi[s]) / length(f_hat)
    est[b] <- adj
  }
  est
}
prev_rows <- list()
for (cn in c("relevant", "distrust", "trust", "incivil")) {
  f <- D[[paste0("f_", cn)]]; y <- D[[paste0("y_", cn)]]
  naive <- mean(f)
  corrected <- mean(D[[paste0("t_", cn)]])
  bs <- boot_dsl(f, y, D$R, D$pi)
  prev_rows[[cn]] <- data.table(
    quantity = cn, naive = naive, corrected = corrected,
    ci_low = unname(quantile(bs, .025)), ci_high = unname(quantile(bs, .975)),
    shift_pp = 100 * (corrected - naive))
}
prev <- rbindlist(prev_rows)
num <- c("naive", "corrected", "ci_low", "ci_high")
prev[, (num) := lapply(.SD, function(x) round(x, 4)), .SDcols = num]
prev[, shift_pp := round(shift_pp, 2)]
fwrite(prev, "output/tables/prevalence_corrected.csv")
cat("\n[S12] prevalence: naive vs DSL-corrected\n"); print(prev)

## ---- RQ1/RQ2 by venue, month, topic ----------------------------------------
## The DSL correction is reported for POOLED estimates only. Split by month it
## rests on ~60 human-coded units per cell, and the pseudo-outcome's variance
## scales with 1/pi, so monthly "corrected" values swing wildly (0.7% to 25.5%
## for incivility) without that meaning anything. Monthly series are reported
## naive, with the pooled correction stated alongside.
by_grp <- function(g, corrected = FALSE) {
  out <- D[, .(n = .N, distrust = mean(f_distrust), trust = mean(f_trust),
               incivil = mean(f_incivil)), by = g]
  if (corrected)
    out <- merge(out, D[, .(distrust_corr = mean(t_distrust),
                            incivil_corr = mean(t_incivil)), by = g], by = g)
  out
}
fwrite(by_grp("subreddit", corrected = TRUE), "output/tables/by_subreddit.csv")
ts <- by_grp("ym")[order(ym)]
fwrite(ts, "output/tables/timeseries.csv")
cat("\n[S12] monthly series\n"); print(ts)
if ("topic" %in% names(D)) fwrite(by_grp("topic"), "output/tables/by_topic.csv")

## ---- RQ3: multilevel model of incivility -----------------------------------
## Comments nest in threads nest in venues. Treating a million comments as a
## million independent observations would understate every standard error, and
## it is the first thing a reader checks.
M <- D[!is.na(depth)]
M[, `:=`(incivil = f_incivil > .5,
         stance3 = factor(fifelse(pred_stance %in% c("trust","distrust","ambivalent"),
                                  pred_stance, "non_evaluative"),
                          levels = c("non_evaluative","trust","distrust","ambivalent")),
         log_words = log1p(n_words),
         depth_c = pmin(depth, 10),
         month = factor(ym),
         venue = factor(subreddit))]
## fit on a manageable random subset of threads; the random effects need many
## groups, not many rows per group
## A random-intercept logistic over ~18,000 thread levels and 250,000 rows does
## not converge in reasonable time with lme4. glmmTMB handles the same model far
## faster, and the estimates are driven by the number of GROUPS rather than rows,
## so a 10,000-thread sample loses very little precision on the thread variance.
set.seed(1); keep_thr <- sample(unique(M$link_id), min(10000, uniqueN(M$link_id)))
MS <- M[link_id %in% keep_thr]
if (nrow(MS) > 80000) MS <- MS[sample(.N, 80000)]
cat(sprintf("\n[S12] multilevel model on %s comments in %s threads\n",
            format(nrow(MS), big.mark = ","), format(uniqueN(MS$link_id), big.mark = ",")))

## Continuous predictors are standardised so every odds ratio is "per standard
## deviation" and the coefficients are comparable. Left raw, caps_ratio is a
## 0-1 proportion and its odds ratio describes a jump from all-lowercase to
## ALL-CAPS, which came out as 2.9e11 -- arithmetically correct and useless.
zs <- function(x) as.numeric(scale(x))
MS[, `:=`(log_words = zs(log_words), depth_c = zs(depth_c),
          caps_ratio = zs(caps_ratio), n_2ndperson = zs(n_2ndperson))]
form <- incivil ~ stance3 + log_words + depth_c + caps_ratio + n_2ndperson +
        venue + month + (1 | link_id)
fit <- tryCatch(glmmTMB(form, data = MS, family = binomial),
                error = function(e) { message("glmmTMB failed: ", conditionMessage(e)); NULL })
if (!is.null(fit)) {
  co <- as.data.table(summary(fit)$coefficients$cond, keep.rownames = "term")
  setnames(co, c("term", "estimate", "se", "z", "p"))
  co[, `:=`(odds_ratio = exp(estimate),
            or_low = exp(estimate - 1.96 * se), or_high = exp(estimate + 1.96 * se))]
  co[, p_adj := p.adjust(p, method = "BH")]
  numc <- c("estimate","se","z","odds_ratio","or_low","or_high")
  co[, (numc) := lapply(.SD, function(x) round(x, 4)), .SDcols = numc]
  fwrite(co, "output/tables/model_incivility.csv")
  cat("\n[S12] incivility model (odds ratios)\n")
  print(co[!grepl("^month", term), .(term, odds_ratio, or_low, or_high, p_adj)])
  writeLines(capture.output(print(summary(fit))), "output/tables/model_incivility_full.txt")
}

## ---- the conversational dynamic: does incivility beget incivility? ---------
## Estimated WITHIN threads. A thread fixed effect differences out the topic,
## the venue and the provocation that started the conversation, so the
## comparison is between replies in the same conversation rather than between
## conversations that differ in every respect.
RP <- D[!is.na(parent_cid)]
RP <- merge(RP, D[, .(parent_cid = id, parent_incivil = f_incivil > .5,
                      parent_stance = pred_stance)], by = "parent_cid")
cat(sprintf("\n[S12] cascade model: %s reply pairs\n", format(nrow(RP), big.mark = ",")))
set.seed(2); kt <- sample(unique(RP$link_id), min(10000, uniqueN(RP$link_id)))
RS <- RP[link_id %in% kt]
if (nrow(RS) > 80000) RS <- RS[sample(.N, 80000)]
RS[, `:=`(incivil = f_incivil > .5,
          log_words = as.numeric(scale(log1p(n_words))),
          depth_c = as.numeric(scale(pmin(depth, 10))))]
casc <- tryCatch(glmmTMB(incivil ~ parent_incivil + log_words + depth_c + (1 | link_id),
                         data = RS, family = binomial),
                 error = function(e) { message("cascade failed: ", conditionMessage(e)); NULL })
if (!is.null(casc)) {
  cc <- as.data.table(summary(casc)$coefficients$cond, keep.rownames = "term")
  setnames(cc, c("term", "estimate", "se", "z", "p"))
  cc[, `:=`(odds_ratio = round(exp(estimate), 3),
            or_low = round(exp(estimate - 1.96*se), 3),
            or_high = round(exp(estimate + 1.96*se), 3))]
  fwrite(cc, "output/tables/model_cascade.csv")
  cat("\n[S12] incivility cascade, within threads\n")
  print(cc[, .(term, odds_ratio, or_low, or_high, p = signif(p, 3))])
  cat(sprintf("   raw: P(incivil | civil parent) = %.3f, P(incivil | uncivil parent) = %.3f\n",
              RP[parent_incivil == FALSE, mean(f_incivil > .5)],
              RP[parent_incivil == TRUE,  mean(f_incivil > .5)]))
}

## ---- removal as a bound on the outcome -------------------------------------
## Deleted and removed comments were dropped in S1, and moderator removal is not
## random with respect to incivility. Reporting the removal rate by venue makes
## the direction of the bias explicit: observed incivility is a floor, and the
## floor is lowest exactly where moderation is strictest.
raw <- as.data.table(read_parquet("data/parquet/comments_raw.parquet"))
rm_rate <- raw[, .(removed = mean(body %in% c("[deleted]", "[removed]")), n = .N),
               by = subreddit][order(-removed)]
obs <- D[, .(observed_incivility = mean(f_incivil > .5)), by = subreddit]
bound <- merge(rm_rate, obs, by = "subreddit")
bound[, worst_case_upper := observed_incivility * (1 - removed) + removed]
bound[, (names(bound)[-1]) := lapply(.SD, function(x) round(x, 4)), .SDcols = -1]
fwrite(bound, "output/tables/removal_bound.csv")
cat("\n[S12] incivility bounds under non-random removal\n"); print(bound)
