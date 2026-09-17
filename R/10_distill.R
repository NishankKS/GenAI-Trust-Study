## ---------------------------------------------------------------------------
## S10 -- DISTILLATION: FROM THE LLM-LABELLED SAMPLE TO THE FULL CORPUS
##
## The LLM is the teacher and cannot be run on 824,518 comments inside a free
## API quota. So it teaches a cheap student -- regularised logistic regression
## over sentence embeddings plus interpretable surface features -- which is then
## applied to every comment.
##
## Two rules make this defensible rather than circular:
##
##   1. The student is TRAINED on LLM labels but VALIDATED against the HUMAN
##      gold standard. A student that faithfully reproduces its teacher's
##      mistakes is worthless, and reporting its agreement with the teacher as
##      though it were accuracy is the first error a careful reader looks for.
##
##   2. Its output is CALIBRATED and kept as probabilities, because the error
##      correction in S12 consumes probabilities. A miscalibrated classifier
##      would corrupt every population estimate downstream.
##
## Memory note: 824,518 x 384 embeddings materialise to ~2.5 GB as an R matrix,
## and glmnet needs its own copy. Embeddings are therefore streamed from Parquet
## through DuckDB -- training touches only the sampled rows, and prediction runs
## one 50,000-row block at a time.
##
## Out: data/derived/distilled_preds.parquet
##      output/tables/distill_performance.csv, calibration.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(glmnet)
  library(duckdb); library(DBI)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")
set.seed(20260901)
INCIV <- cb_levels("incivility")
EMB   <- "data/derived/embeddings.parquet"
ECOLS <- paste0("e", 0:383)
SURF  <- c("n_words", "caps_ratio", "n_question", "n_exclaim", "n_2ndperson",
           "n_links", "depth")

con <- dbConnect(duckdb())
n_emb <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM read_parquet('%s')", EMB))$n

ac   <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
lab  <- as.data.table(read_parquet("data/derived/llm_labels_A.parquet"))
gold <- fread("data/derived/gold_labels.csv")
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
if (!"eligible" %in% names(samp)) samp[, eligible := TRUE]
lab <- lab[id %in% samp[eligible == TRUE, id]]          # honour the frame correction
lab[, any_incivility := rowSums(as.matrix(.SD)) > 0, .SDcols = intersect(INCIV, names(lab))]
cat(sprintf("[S10] embeddings %s x %d | LLM labels %s | gold %d\n",
            format(n_emb, big.mark = ","), length(ECOLS),
            format(nrow(lab), big.mark = ","), nrow(gold)))

## ---- surface features, and the scaling learned once on the corpus ----------
SF <- ac[, c("id", SURF), with = FALSE]
SF[, depth := fifelse(is.na(depth), -1, as.numeric(depth))]
SF[, n_words := log1p(n_words)]
ctr <- vapply(SF[, ..SURF], mean, numeric(1))
scl <- vapply(SF[, ..SURF], function(x) { s <- sd(x); if (s == 0) 1 else s }, numeric(1))
setkey(SF, id)

## ---- feature matrix for a set of ids ---------------------------------------
build_X <- function(ids) {
  e <- as.data.table(dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet('%s') WHERE id IN (%s)",
    EMB, paste0("'", ids, "'", collapse = ","))))
  if (!nrow(e)) return(NULL)
  s <- SF[J(e$id)]
  M <- cbind(as.matrix(e[, ..ECOLS]),
             sweep(sweep(as.matrix(s[, ..SURF]), 2, ctr, "-"), 2, scl, "/"))
  colnames(M) <- c(ECOLS, SURF)
  rownames(M) <- e$id
  storage.mode(M) <- "double"
  M
}

## ---- splits -----------------------------------------------------------------
## Train on LLM labels, EXCLUDING every comment in the human test split, so the
## test set stays untouched by anything the student ever saw.
test_ids  <- gold[gold_split == "test", id]
train_ids <- setdiff(lab$id, test_ids)
Xtr <- build_X(train_ids)
train_ids <- rownames(Xtr)
lab_tr <- lab[match(train_ids, id)]
cat(sprintf("[S10] train %s (LLM-labelled) | test %d (human, untouched)\n",
            format(length(train_ids), big.mark = ","), length(test_ids)))

fit_one <- function(nm, y, family) {
  keep <- !is.na(y)
  if (length(unique(y[keep])) < 2) { cat(sprintf("[S10] %s: one class only, skipped\n", nm)); return(NULL) }
  nf <- max(3, min(5, floor(sum(keep) / 20)))
  cv <- cv.glmnet(Xtr[keep, , drop = FALSE], y[keep], family = family,
                  alpha = 0.1, nfolds = nf, standardize = FALSE)
  cat(sprintf("[S10] %-11s n=%d  lambda.1se=%.5f\n", nm, sum(keep), cv$lambda.1se))
  cv
}
models <- list(
  relevance  = fit_one("relevance",  lab_tr$relevance == "relevant", "binomial"),
  incivility = fit_one("incivility", lab_tr$any_incivility,          "binomial"),
  stance     = fit_one("stance", factor(lab_tr$stance, cb_levels("stance")), "multinomial"))

## ---- Platt calibration on the training predictions --------------------------
cal <- list()
for (nm in c("relevance", "incivility")) {
  if (is.null(models[[nm]])) next
  y <- if (nm == "relevance") lab_tr$relevance == "relevant" else lab_tr$any_incivility
  keep <- !is.na(y)
  p <- as.numeric(predict(models[[nm]], Xtr[keep, , drop = FALSE],
                          s = "lambda.1se", type = "response"))
  cal[[nm]] <- glm(y[keep] ~ qlogis(pmin(pmax(p, 1e-6), 1 - 1e-6)), family = binomial)
}
apply_bin <- function(nm, X) {
  if (is.null(models[[nm]])) return(rep(NA_real_, nrow(X)))
  p <- as.numeric(predict(models[[nm]], X, s = "lambda.1se", type = "response"))
  if (!is.null(cal[[nm]]))
    p <- as.numeric(predict(cal[[nm]],
           newdata = data.frame(p = qlogis(pmin(pmax(p, 1e-6), 1 - 1e-6))), type = "response"))
  p
}

## ---- evaluate against the HUMAN gold standard -------------------------------
Xte <- build_X(test_ids)
G <- gold[match(rownames(Xte), id)]
f1b <- function(truth, pred) {
  tp <- sum(truth & pred); fp <- sum(!truth & pred); fn <- sum(truth & !pred)
  if (tp == 0) return(0)
  p <- tp/(tp+fp); r <- tp/(tp+fn); 2*p*r/(p+r)
}
pr <- apply_bin("relevance", Xte); pinc <- apply_bin("incivility", Xte)
ps <- if (is.null(models$stance)) rep(NA_character_, nrow(Xte)) else
        as.character(predict(models$stance, Xte, s = "lambda.1se", type = "class"))
perf <- rbind(
  data.table(construct = "relevance", n = nrow(Xte),
             accuracy = mean((pr > .5) == (G$relevance == "relevant"), na.rm = TRUE),
             f1 = f1b(G$relevance == "relevant", pr > .5)),
  data.table(construct = "any_incivility", n = nrow(Xte),
             accuracy = mean((pinc > .5) == G$any_incivility, na.rm = TRUE),
             f1 = f1b(G$any_incivility, pinc > .5)),
  data.table(construct = "stance", n = nrow(Xte),
             accuracy = mean(ps == G$stance, na.rm = TRUE), f1 = NA_real_))
perf[, `:=`(accuracy = round(accuracy, 3), f1 = round(f1, 3))]
fwrite(perf, "output/tables/distill_performance.csv")
cat("\n[S10] student vs HUMAN gold (locked test)\n"); print(perf)

bins <- cut(pinc, breaks = seq(0, 1, .1), include.lowest = TRUE)
ct <- data.table(bin = bins, p = pinc, y = G$any_incivility)[
        , .(n = .N, mean_pred = mean(p), observed = mean(y)), by = bin][order(bin)]
ct[, ece_contrib := n / sum(n) * abs(mean_pred - observed)]
fwrite(ct, "output/tables/calibration.csv")
cat(sprintf("[S10] expected calibration error (incivility) = %.3f\n", sum(ct$ece_contrib)))

## ---- apply to the whole corpus, one block at a time -------------------------
cat("[S10] scoring the full corpus\n")
all_ids <- ac$id
blocks <- split(all_ids, ceiling(seq_along(all_ids) / 50000L))
out <- vector("list", length(blocks))
for (i in seq_along(blocks)) {
  X <- build_X(blocks[[i]])
  if (is.null(X)) next
  d <- data.table(id = rownames(X),
                  p_relevant = apply_bin("relevance", X),
                  p_incivility = apply_bin("incivility", X))
  if (!is.null(models$stance)) {
    sp <- drop(predict(models$stance, X, s = "lambda.1se", type = "response"))
    for (k in colnames(sp)) d[[paste0("p_", k)]] <- sp[, k]
    d[, pred_stance := colnames(sp)[max.col(sp, ties.method = "first")]]
  } else d[, pred_stance := NA_character_]
  out[[i]] <- d
  if (i %% 4 == 0 || i == length(blocks))
    cat(sprintf("  block %d/%d\n", i, length(blocks)))
}
res <- rbindlist(out, fill = TRUE)
res[, `:=`(pred_relevance  = fifelse(p_relevant > .5, "relevant", "not_relevant"),
           pred_incivility = p_incivility > .5)]
write_parquet(res, "data/derived/distilled_preds.parquet", compression = "zstd")
dbDisconnect(con, shutdown = TRUE)

cat(sprintf("[S10] %s comments scored\n", format(nrow(res), big.mark = ",")))
cat(sprintf("      relevant %.1f%% | incivil %.1f%%\n",
            100*mean(res$pred_relevance == "relevant"), 100*mean(res$pred_incivility)))
print(res[, .N, by = pred_stance][order(-N)])
