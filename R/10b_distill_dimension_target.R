## ---------------------------------------------------------------------------
## S10b -- DISTILLATION EXTENSION: DIMENSION AND TARGET TO THE FULL CORPUS
##
## S10 (10_distill.R) distills relevance, any_incivility and stance to the
## full 824,518-comment corpus, but never trained dimension/target -- RQ1's
## own wording ("along which dimensions, and directed at which targets?")
## is unanswered at corpus scale as a result. This is the fix: identical
## architecture to S10's stance model (regularised multinomial logistic
## regression over the same 384-dim sentence embeddings + surface
## features), same train/test split (LLM-labelled sample minus the locked
## human test split), evaluated against the same 150-comment locked gold
## test set. Additive -- does not touch 10_distill.R or its outputs.
##
## No new embeddings are computed and no LLM/API calls are made. The
## embeddings (data/derived/embeddings.parquet, 824,518 x 384) were already
## computed for the whole corpus by R/07_embed.py; this script only fits two
## more lightweight classifier heads on top of them and re-predicts, so
## there is nothing here for a GPU to accelerate -- glmnet is CPU-only, and
## fitting/predicting a few thousand x few hundred matrix is sub-second
## regardless of the fitting device. See PROJECT_STATUS-style note in the
## chat: GPU is genuinely not a bottleneck for this step.
##
## Out: data/derived/distilled_preds_dimtarget.parquet
##      output/tables/distill_performance_dimtarget.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(glmnet)
  library(duckdb); library(DBI)
})
ROOT <- "/home/nishanksatish/Documents/Final_R/R"
setwd(ROOT)
source("R/codebook.R")
set.seed(20260901)
EMB   <- "data/derived/embeddings.parquet"
ECOLS <- paste0("e", 0:383)
SURF  <- c("n_words", "caps_ratio", "n_question", "n_exclaim", "n_2ndperson",
           "n_links", "depth")

con <- dbConnect(duckdb())

ac   <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
lab  <- as.data.table(read_parquet("data/derived/llm_labels_A.parquet"))
gold <- fread("data/derived/gold_labels.csv")
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
if (!"eligible" %in% names(samp)) samp[, eligible := TRUE]
lab <- lab[id %in% samp[eligible == TRUE, id]]
cat(sprintf("[S10b] LLM labels %s | gold %d (dimension/target both present in gold)\n",
            format(nrow(lab), big.mark = ","), nrow(gold)))

SF <- ac[, c("id", SURF), with = FALSE]
SF[, depth := fifelse(is.na(depth), -1, as.numeric(depth))]
SF[, n_words := log1p(n_words)]
ctr <- vapply(SF[, ..SURF], mean, numeric(1))
scl <- vapply(SF[, ..SURF], function(x) { s <- sd(x); if (s == 0) 1 else s }, numeric(1))
setkey(SF, id)

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

test_ids  <- gold[gold_split == "test", id]
train_ids <- setdiff(lab$id, test_ids)
Xtr <- build_X(train_ids)
train_ids <- rownames(Xtr)
lab_tr <- lab[match(train_ids, id)]
cat(sprintf("[S10b] train %s (LLM-labelled) | test %d (human, untouched)\n",
            format(length(train_ids), big.mark = ","), length(test_ids)))

fit_multinom <- function(nm, y_raw, levels) {
  y <- factor(y_raw, levels = levels)
  keep <- !is.na(y)
  nf <- max(3, min(5, floor(sum(keep) / 20)))
  cv <- cv.glmnet(Xtr[keep, , drop = FALSE], y[keep], family = "multinomial",
                  alpha = 0.1, nfolds = nf, standardize = FALSE)
  cat(sprintf("[S10b] %-10s n=%d classes=%d lambda.1se=%.5f\n",
              nm, sum(keep), length(levels), cv$lambda.1se))
  cv
}
dim_levels <- cb_levels("dimension")
tgt_levels <- cb_levels("target")
models <- list(
  dimension = fit_multinom("dimension", lab_tr$dimension, dim_levels),
  target    = fit_multinom("target",    lab_tr$target,    tgt_levels)
)

## ---- evaluate against the HUMAN gold standard (locked test only) ----------
Xte <- build_X(test_ids)
G <- gold[match(rownames(Xte), id)]
pred_class <- function(model, X) as.character(predict(model, X, s = "lambda.1se", type = "class"))
pd <- pred_class(models$dimension, Xte)
pt <- pred_class(models$target, Xte)
perf <- rbind(
  data.table(construct = "dimension", n = nrow(Xte), accuracy = round(mean(pd == G$dimension, na.rm = TRUE), 3)),
  data.table(construct = "target",    n = nrow(Xte), accuracy = round(mean(pt == G$target, na.rm = TRUE), 3))
)
fwrite(perf, "output/tables/distill_performance_dimtarget.csv")
cat("\n[S10b] student vs HUMAN gold (locked test)\n"); print(perf)

## ---- apply to the whole corpus, one block at a time ------------------------
cat("[S10b] scoring the full corpus\n")
all_ids <- ac$id
blocks <- split(all_ids, ceiling(seq_along(all_ids) / 50000L))
out <- vector("list", length(blocks))
for (i in seq_along(blocks)) {
  X <- build_X(blocks[[i]])
  if (is.null(X)) next
  d <- data.table(id = rownames(X))
  sp_dim <- drop(predict(models$dimension, X, s = "lambda.1se", type = "response"))
  for (k in colnames(sp_dim)) d[[paste0("p_dimension_", k)]] <- sp_dim[, k]
  d[, pred_dimension := colnames(sp_dim)[max.col(sp_dim, ties.method = "first")]]
  sp_tgt <- drop(predict(models$target, X, s = "lambda.1se", type = "response"))
  for (k in colnames(sp_tgt)) d[[paste0("p_target_", k)]] <- sp_tgt[, k]
  d[, pred_target := colnames(sp_tgt)[max.col(sp_tgt, ties.method = "first")]]
  out[[i]] <- d
  if (i %% 4 == 0 || i == length(blocks)) cat(sprintf("  block %d/%d\n", i, length(blocks)))
}
res <- rbindlist(out, fill = TRUE)
write_parquet(res, "data/derived/distilled_preds_dimtarget.parquet", compression = "zstd")
dbDisconnect(con, shutdown = TRUE)

cat(sprintf("\n[S10b] %s comments scored\n", format(nrow(res), big.mark = ",")))
print(res[, .N, by = pred_dimension][order(-N)])
print(res[, .N, by = pred_target][order(-N)])
