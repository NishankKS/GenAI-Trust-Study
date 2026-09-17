## ---------------------------------------------------------------------------
## S9 -- THE VALIDATION TABLE
##
## Every instrument in the study is scored against the SAME human gold standard,
## on the SAME locked test split, with the SAME metric. This is the table the
## whole methods section rests on, and it is the reason the dictionary layer is
## kept: not because it is used for inference, but because showing it lose --
## measurably, on the same footing -- is what licenses the LLM measures.
##
## The test split (n = 150) is opened here for the first time. Nothing in S4-S8
## was tuned against it.
##
## Input : data/derived/gold_labels.csv, llm_labels_{A,B,C}.parquet,
##         lexical_scores.parquet, distilled_preds.parquet (if present)
## Output: output/tables/validation.csv
##         output/tables/confusion_*.csv
##         output/tables/intermodel_agreement.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(irr)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")
INCIV <- cb_levels("incivility")

gold <- fread("data/derived/gold_labels.csv")
if (gold$standard[1] != "human")
  warning("gold standard is PROVISIONAL -- these numbers are not validation")
test <- gold[gold_split == "test"]
cat(sprintf("[S9] locked test set: n = %d (source: %s)\n", nrow(test), gold$standard[1]))

## ---- metrics ---------------------------------------------------------------
## Macro-F1 is averaged over classes PRESENT IN THE TRUTH, so a class the gold
## standard never contains cannot inflate or deflate the score.
prf <- function(truth, pred, lv = NULL) {
  truth <- as.character(truth); pred <- as.character(pred)
  ok <- !is.na(truth) & !is.na(pred)
  truth <- truth[ok]; pred <- pred[ok]
  if (is.null(lv)) lv <- sort(unique(truth))
  res <- rbindlist(lapply(lv, function(k) {
    tp <- sum(truth == k & pred == k); fp <- sum(truth != k & pred == k)
    fn <- sum(truth == k & pred != k)
    p <- if (tp + fp == 0) NA_real_ else tp / (tp + fp)
    r <- if (tp + fn == 0) NA_real_ else tp / (tp + fn)
    f <- if (is.na(p) || is.na(r) || p + r == 0) 0 else 2 * p * r / (p + r)
    data.table(class = k, n = sum(truth == k), precision = p, recall = r, f1 = f)
  }))
  list(per_class = res,
       macro_f1 = mean(res$f1, na.rm = TRUE),
       accuracy = mean(truth == pred),
       kappa = tryCatch(kappa2(cbind(truth, pred))$value, error = function(e) NA_real_))
}

score_row <- function(instrument, coverage, cost, construct, truth, pred, lv = NULL) {
  m <- prf(truth, pred, lv)
  data.table(construct = construct, instrument = instrument, coverage = coverage,
             cost = cost, n_test = sum(!is.na(pred) & !is.na(truth)),
             macro_f1 = m$macro_f1, accuracy = m$accuracy, kappa = m$kappa)
}

## ---- assemble the instruments ---------------------------------------------
get_llm <- function(p) if (file.exists(p)) as.data.table(read_parquet(p)) else NULL
A <- get_llm("data/derived/llm_labels_A.parquet")
B <- get_llm("data/derived/llm_labels_B.parquet")
C <- get_llm("data/derived/llm_labels_C.parquet")
## The lexical baseline is a row of the validation table, not a dependency of
## it: the script must be runnable at any point in the pipeline.
lex <- if (file.exists("data/derived/lexical_scores.parquet"))
         as.data.table(read_parquet("data/derived/lexical_scores.parquet")) else NULL
dis <- if (file.exists("data/derived/distilled_preds.parquet"))
         as.data.table(read_parquet("data/derived/distilled_preds.parquet")) else NULL
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))

add_any_inc <- function(d) {
  present <- intersect(INCIV, names(d))
  if (!length(present)) return(d)
  d[, any_incivility := rowSums(as.matrix(.SD)) > 0, .SDcols = present][]
}
for (nm in c("A", "B", "C")) if (!is.null(get(nm))) assign(nm, add_any_inc(get(nm)))

T <- copy(test)
T[samp,  on = "id", has_ai_ref := i.has_ai_ref]
if (!is.null(lex))
  T[lex, on = "id", `:=`(lsd_stance = i.lsd_stance, dict_inc = i.dict_any_incivility)]
if (!"lsd_stance" %in% names(T)) T[, `:=`(lsd_stance = NA_character_, dict_inc = NA)]
if (!is.null(A)) T[A, on = "id", `:=`(A_rel = i.relevance, A_st = i.stance, A_inc = i.any_incivility)]
if (!is.null(B)) T[B, on = "id", `:=`(B_rel = i.relevance, B_st = i.stance, B_inc = i.any_incivility)]
if (!is.null(C)) T[C, on = "id", C_inc := i.any_incivility]
if (!is.null(dis)) T[dis, on = "id", `:=`(D_rel = i.pred_relevance, D_st = i.pred_stance,
                                          D_inc = i.pred_incivility)]

## The two-family ensemble. Where the families agree, that is the label. Where
## they disagree the case is UNRESOLVED until self-consistency (R/04b) settles
## it by majority vote; it is left NA rather than quietly falling back to the
## primary annotator, which would make this row a duplicate of the gpt-oss-120b
## row while claiming to be something else.
SC <- if (file.exists("data/derived/selfconsistency.parquet"))
        as.data.table(read_parquet("data/derived/selfconsistency.parquet")) else NULL
if (!is.null(A) && !is.null(B)) {
  ## the annotations come back as factors; compare and store as character
  T[, `:=`(A_st = as.character(A_st), B_st = as.character(B_st),
           A_rel = as.character(A_rel), B_rel = as.character(B_rel))]
  T[, E_st  := fifelse(!is.na(A_st)  & A_st  == B_st,  A_st,  NA_character_)]
  T[, E_rel := fifelse(!is.na(A_rel) & A_rel == B_rel, A_rel, NA_character_)]
  T[, E_inc := (A_inc %in% TRUE) & (B_inc %in% TRUE)]
  if (!is.null(SC)) T[SC, on = "id", E_st := fifelse(is.na(E_st), i.sc_stance, E_st)]
  cat(sprintf("[S9] ensemble resolves %d of %d test comments (%.0f%%)%s
",
              sum(!is.na(T$E_st)), nrow(T), 100 * mean(!is.na(T$E_st)),
              if (is.null(SC)) "; self-consistency not yet run" else ""))
}

## ---- score ------------------------------------------------------------------
rows <- list()
LV_ST <- cb_levels("stance")

## RELEVANCE ------------------------------------------------------------------
rows[[length(rows)+1]] <- score_row(
  "Lexical AI-reference prefilter", "full corpus", "free", "relevance",
  T$relevance, fifelse(T$has_ai_ref, "relevant", "not_relevant"))
if (!is.null(dis)) rows[[length(rows)+1]] <- score_row(
  "Distilled classifier (embeddings)", "full corpus", "one CPU night", "relevance",
  T$relevance, T$D_rel)
if (!is.null(A)) rows[[length(rows)+1]] <- score_row(
  "LLM gpt-oss-120b", "5,000 sampled", "~625 requests", "relevance", T$relevance, T$A_rel)
if (!is.null(B)) rows[[length(rows)+1]] <- score_row(
  "LLM qwen3.8-27b", "5,000 sampled", "~625 requests", "relevance", T$relevance, T$B_rel)

## STANCE ---------------------------------------------------------------------
if (!all(is.na(T$lsd_stance))) rows[[length(rows)+1]] <- score_row(
  "Dictionary LSD2015 (net tone)", "full corpus", "free", "stance",
  T$stance, T$lsd_stance, LV_ST)
if (!is.null(dis)) rows[[length(rows)+1]] <- score_row(
  "Distilled classifier (embeddings)", "full corpus", "one CPU night", "stance",
  T$stance, T$D_st, LV_ST)
if (!is.null(A)) rows[[length(rows)+1]] <- score_row(
  "LLM gpt-oss-120b", "5,000 sampled", "~625 requests", "stance", T$stance, T$A_st, LV_ST)
if (!is.null(B)) rows[[length(rows)+1]] <- score_row(
  "LLM qwen3.8-27b", "5,000 sampled", "~625 requests", "stance", T$stance, T$B_st, LV_ST)
if (!is.null(A) && !is.null(B)) rows[[length(rows)+1]] <- score_row(
  "LLM two-family ensemble (agreement only)", "5,000 sampled", "~1,250 requests", "stance",
  T$stance, T$E_st, LV_ST)

## INCIVILITY ------------------------------------------------------------------
b <- function(x) fifelse(x %in% TRUE, "yes", "no")
if (!all(is.na(T$dict_inc))) rows[[length(rows)+1]] <- score_row(
  "Wordlist (vulgarity/name-calling/bad-faith)", "full corpus", "free", "any_incivility",
  b(T$any_incivility), b(T$dict_inc))
if (!is.null(dis)) rows[[length(rows)+1]] <- score_row(
  "Distilled classifier (embeddings)", "full corpus", "one CPU night", "any_incivility",
  b(T$any_incivility), b(T$D_inc))
if (!is.null(A)) rows[[length(rows)+1]] <- score_row(
  "LLM gpt-oss-120b", "5,000 sampled", "~625 requests", "any_incivility",
  b(T$any_incivility), b(T$A_inc))
if (!is.null(C)) rows[[length(rows)+1]] <- score_row(
  "LLM safeguard-20b (codebook as policy)", "5,000 sampled", "~625 requests",
  "any_incivility", b(T$any_incivility), b(T$C_inc))

val <- rbindlist(rows)
val[, `:=`(macro_f1 = round(macro_f1, 3), accuracy = round(accuracy, 3),
           kappa = round(kappa, 3))]
setorder(val, construct, -macro_f1)
fwrite(val, "output/tables/validation.csv")
cat("\n[S9] VALIDATION (locked test set)\n"); print(val)

## ---- confusion matrices ----------------------------------------------------
cm <- function(truth, pred, lv, file) {
  ok <- !is.na(truth) & !is.na(pred)
  if (!sum(ok)) return(invisible(NULL))
  m <- as.data.table(table(human = factor(truth[ok], lv), predicted = factor(pred[ok], lv)))
  fwrite(dcast(m, human ~ predicted, value.var = "N"), file)
}
if (!is.null(A)) {
  cm(T$stance, T$A_st, LV_ST, "output/tables/confusion_stance_llmA.csv")
  cm(b(T$any_incivility), b(T$A_inc), c("no","yes"), "output/tables/confusion_incivility_llmA.csv")
  pc <- prf(T$stance, T$A_st, LV_ST)$per_class
  cat("\n[S9] gpt-oss-120b, stance, per class\n"); print(pc)
  fwrite(pc, "output/tables/perclass_stance_llmA.csv")
}

## ---- inter-model agreement (a reliability statistic in its own right) ------
if (!is.null(A) && !is.null(B)) {
  M <- merge(A[, .(id, A_st = stance, A_rel = relevance, A_inc = any_incivility)],
             B[, .(id, B_st = stance, B_rel = relevance, B_inc = any_incivility)], by = "id")
  ## integer-coded for the same reason as above
  ka <- function(x, y) {
    u <- sort(unique(na.omit(c(as.character(x), as.character(y)))))
    if (length(u) < 2) return(NA_real_)
    tryCatch(kripp.alpha(rbind(match(as.character(x), u), match(as.character(y), u)),
                         method = "nominal")$value, error = function(e) NA_real_)
  }
  ia <- data.table(
    variable  = c("relevance", "stance", "any_incivility"),
    n         = nrow(M),
    alpha     = c(ka(M$A_rel, M$B_rel), ka(M$A_st, M$B_st), ka(M$A_inc, M$B_inc)),
    pct_agree = c(mean(M$A_rel == M$B_rel), mean(M$A_st == M$B_st), mean(M$A_inc == M$B_inc)))
  ia[, alpha := round(alpha, 3)][, pct_agree := round(pct_agree, 3)]
  fwrite(ia, "output/tables/intermodel_agreement.csv")
  cat("\n[S9] inter-MODEL agreement (gpt-oss-120b vs qwen3.8-27b), full annotated sample\n")
  print(ia)
  cat("   compare against inter-CODER alpha in output/tables/reliability.csv\n")
  ## the comments the two families disagree on are exactly the ones worth
  ## escalating to self-consistency, and worth reading in the discussion
  fwrite(M[A_st != B_st, .(id)], "data/derived/disagreements.csv")
  cat(sprintf("   %d stance disagreements written for escalation\n", sum(M$A_st != M$B_st)))
}
