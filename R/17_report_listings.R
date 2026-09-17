## ---------------------------------------------------------------------------
## S17 -- LISTING OUTPUTS FOR THE REPORT
##
## Each block below is the code that appears in the report, run here so that the
## console output printed beneath it in the report is genuine rather than
## transcribed. Outputs are written to output/listings/ and read into the LaTeX
## source. Nothing here recomputes a published result from scratch except where
## a recomputation is itself the check (reliability, validation metrics), and in
## those cases the recomputed values are compared against the shipped tables.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({library(data.table)})
ROOT <- "/home/nishanksatish/Documents/Final_R/R"; setwd(ROOT)
OUT <- "output/listings"; dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
cap <- function(name, expr) {
  txt <- capture.output(expr)
  writeLines(txt, file.path(OUT, paste0(name, ".txt")))
  cat("== ", name, " ==\n", sep = ""); writeLines(txt); cat("\n")
}

## ---- L1: the exclusion funnel ----------------------------------------------
cap("l1_funnel", {
  funnel <- fread("output/tables/funnel.csv")
  funnel[, kept := sprintf("%.1f%%", 100 * n / n[1])]
  print(funnel[, .(step, n, kept)])
})

## ---- L2: stratification, allocation and design weights ---------------------
cap("l2_design", {
  d <- fread("output/tables/sampling_design.csv")
  cat(sprintf("strata: %d | allocated n: %s | frame N: %s\n",
              nrow(d), format(sum(d$n_h), big.mark = ","),
              format(sum(d$N_h), big.mark = ",")))
  cat(sprintf("inclusion probability pi_h: %.5f to %.5f (ratio %.0f)\n",
              min(d$pi_h), max(d$pi_h), max(d$pi_h) / min(d$pi_h)))
  cat(sprintf("design weight w_h:          %.1f to %.1f\n", min(d$w_h), max(d$w_h)))
  cat("\nlargest and smallest strata:\n")
  print(rbind(head(d[order(-N_h)], 3), tail(d[order(-N_h)], 2)))
})

## ---- L3: realised sample and its splits ------------------------------------
cap("l3_sample", {
  s <- fread("data/derived/annotation_sample.csv", na.strings = c("", "NA"))
  cat(sprintf("annotated sample drawn : %d\n", nrow(s)))
  cat(sprintf("eligible after frame correction: %d\n", sum(s$eligible)))
  cat(sprintf("human-coded subsample  : %d\n", sum(s$in_gold %in% c(TRUE, "TRUE"))))
  print(table(s$gold_split, useNA = "no"))
  g <- fread("data/derived/gold_labels.csv")
  cat(sprintf("\neligible human-coded   : %d\n", nrow(g)))
  print(table(g$gold_split))
})

## ---- L4: Krippendorff's alpha, recomputed from the two coding sheets -------
## Implemented directly rather than called from a package, so the definition
## used is visible: alpha = 1 - Do/De, observed over expected disagreement.
cap("l4_alpha", {
  kripp_alpha_nominal <- function(a, b) {
    ok <- !is.na(a) & !is.na(b)
    a <- as.character(a[ok]); b <- as.character(b[ok]); n <- length(a)
    lv <- sort(unique(c(a, b)))
    Do <- mean(a != b)                                  # observed disagreement
    p  <- table(factor(c(a, b), levels = lv)) / (2 * n)  # marginal distribution
    De <- 1 - sum(p^2)                                   # expected by chance
    De <- De * (2 * n) / (2 * n - 1)                     # small-sample correction
    1 - Do / De
  }
  um <- fread("coding/coding_sheet_UM_annotated.csv", na.strings = c("", "NA"))
  nk <- fread("coding/coding_sheet_NK_annotated.csv", na.strings = c("", "NA"))
  elig <- fread("data/derived/gold_labels.csv")$id
  both <- intersect(intersect(um$id, nk$id), elig)
  A <- um[id %in% both][order(id)]; B <- nk[id %in% both][order(id)]
  vars <- c("relevance", "stance", "dimension", "target", "incivility_direction")
  out <- rbindlist(lapply(vars, function(v) data.table(
    variable = v, n = length(both),
    alpha = round(kripp_alpha_nominal(A[[v]], B[[v]]), 3),
    pct_agree = round(mean(A[[v]] == B[[v]], na.rm = TRUE), 3))))
  print(out)
  shipped <- fread("output/tables/reliability.csv")[variable %in% vars,
                                                    .(variable, shipped = round(alpha, 3))]
  cat("\nagreement with the shipped table:\n")
  print(merge(out[, .(variable, recomputed = alpha)], shipped, by = "variable"))
})

## ---- L5: validation metrics, recomputed for one annotator ------------------
cap("l5_metrics", {
  prf <- function(truth, pred) {
    ok <- !is.na(truth) & !is.na(pred)
    truth <- as.character(truth)[ok]; pred <- as.character(pred)[ok]
    lv <- sort(unique(truth))
    res <- rbindlist(lapply(lv, function(k) {
      tp <- sum(truth == k & pred == k); fp <- sum(truth != k & pred == k)
      fn <- sum(truth == k & pred != k)
      p <- if (tp + fp == 0) NA_real_ else tp / (tp + fp)
      r <- if (tp + fn == 0) NA_real_ else tp / (tp + fn)
      data.table(class = k, n = sum(truth == k), precision = round(p, 3),
                 recall = round(r, 3),
                 f1 = round(if (is.na(p) || is.na(r) || p + r == 0) 0 else
                              2 * p * r / (p + r), 3))
    }))
    po <- mean(truth == pred)
    pe <- sum((table(factor(truth, lv)) / length(truth)) *
              (table(factor(pred,  lv)) / length(pred)))
    list(per_class = res, macro_f1 = round(mean(res$f1, na.rm = TRUE), 3),
         accuracy = round(po, 3), kappa = round((po - pe) / (1 - pe), 3))
  }
  gold <- fread("data/derived/gold_labels.csv")[gold_split == "test"]
  llm  <- fread("data/derived/llm_labels_A.csv", na.strings = c("", "NA"))
  m <- merge(gold[, .(id, truth = stance)], llm[, .(id, pred = stance)], by = "id")
  r <- prf(m$truth, m$pred)
  cat(sprintf("stance, gpt-oss-120b on the locked test split (n = %d)\n", nrow(m)))
  print(r$per_class)
  cat(sprintf("\nmacro F1 = %.3f | accuracy = %.3f | kappa = %.3f\n",
              r$macro_f1, r$accuracy, r$kappa))
})

## ---- L6: distilled classifier, performance and calibration -----------------
cap("l6_distill", {
  print(fread("output/tables/distill_performance.csv"))
  print(fread("output/tables/distill_performance_dimtarget.csv"))
  ct <- fread("output/tables/calibration.csv")
  cat(sprintf("\nexpected calibration error (incivility) = %.3f over %d test comments\n",
              sum(ct$ece_contrib), sum(ct$n)))
})

## ---- L7: topic model output -------------------------------------------------
cap("l7_topics", {
  tp <- fread("output/tables/topic_prevalence.csv")
  tp[, seeded := !grepl("^other", topic)]
  cat(sprintf("modelled topics: %d (%d seeded, %d residual) over %s comments\n",
              nrow(tp), sum(tp$seeded), sum(!tp$seeded),
              format(sum(tp$n), big.mark = ",")))
  print(tp[order(-share)][, .(topic, n, share = round(share, 3), seeded)])
  nmi <- readLines("output/tables/topic_alignment_nmi.txt")[1]
  cat(sprintf("\nresidual share: %.3f | %s\n",
              tp[seeded == FALSE, sum(share)], nmi))
})

## ---- L8: the multilevel model ----------------------------------------------
cap("l8_model", {
  writeLines(head(readLines("output/tables/model_incivility_full.txt"), 26))
})

cat("[S17] listings written to", OUT, "\n")
