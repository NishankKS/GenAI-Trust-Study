## ---------------------------------------------------------------------------
## S6 -- MODEL AND REASONING-EFFORT EXPERIMENT (dev split only)
##
## Two purposes, and they happen to point the same way.
##
## SCIENTIFIC: the annotation procedure should be selected by measurement, not
## asserted. Three variants are scored on the 210-comment DEV split against the
## human codes. The locked test split is not touched.
##
## PRACTICAL: Groq's free tier caps each key at 200,000 tokens per day PER MODEL
## (confirmed from a 429 body). At the 4,167 tokens a medium-effort gpt-oss-120b
## request costs, that is 48 requests per key per day, and the 625-request pass
## would take 3.3 days on four keys. If a cheaper variant measures as well, using
## it is an evidence-based efficiency choice rather than a compromise -- and if
## it measures worse, we know the price of the cheap option and can say so.
##
## Note that each MODEL has its own daily bucket, so variants on different
## models do not compete for quota.
##
## Usage: Rscript R/06_variants.R
## Out:   output/tables/variant_experiment.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(ellmer); library(arrow); library(data.table); library(openssl)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")
INCIV <- cb_levels("incivility")

VARIANTS <- list(
  list(tag = "120b-medium", model = "openai/gpt-oss-120b",          effort = "medium", key = 2),
  list(tag = "120b-low",    model = "openai/gpt-oss-120b",          effort = "low",    key = 3),
  list(tag = "20b-medium",  model = "openai/gpt-oss-20b",           effort = "medium", key = 4),
  list(tag = "qwen-medium", model = "qwen/qwen3.8-27b",             effort = "medium", key = 1)
)
BATCH <- 8L

KEYS <- trimws(readLines("groq_keys.txt", warn = FALSE)); KEYS <- KEYS[nzchar(KEYS)]
gold <- fread("data/derived/gold_labels.csv")
dev  <- gold[gold_split == "dev"]
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
D <- merge(dev, samp[, .(id, text, subreddit, thread_slug, parent_text)], by = "id")
setorder(D, id)
cat(sprintf("[S6] dev split: %d comments, %d batches per variant\n",
            nrow(D), ceiling(nrow(D) / BATCH)))

## ---- schema and prompt (identical across variants; only model/effort vary) --
one <- list(.description = "Annotation of one comment", .additional_properties = FALSE,
            id = type_string("The exact id string given."),
            relevance = type_enum(cb_levels("relevance")),
            stance    = type_enum(cb_levels("stance")),
            dimension = type_enum(cb_levels("dimension")),
            target    = type_enum(cb_levels("target")))
for (nm in INCIV) one[[nm]] <- type_boolean(nm)
one$incivility_direction <- type_enum(cb_levels("incivility_direction"))
one$confidence <- type_number("0 to 1")
schema <- type_object(.additional_properties = FALSE,
                      results = type_array(do.call(type_object, one)))

sys <- paste0(
"You are an expert content analyst coding Reddit comments for a communication-science
study of trust and incivility in discussions about generative AI. You apply the codebook
below exactly as written.

RULES
1. Code only what the comment itself says. Do not infer unstated beliefs.
2. Quoted text, code blocks and URLs were removed before you see the comment.
3. Sarcasm and irony carry their intended meaning, not their literal one.
4. Criticising an AI system is DISTRUST, not automatically incivility.
5. If relevance is not_relevant, set stance to non_evaluative and dimension and target to
   not_applicable. Incivility is still coded for every comment.
6. Think briefly before answering, then return only the structured result.

CODEBOOK
", codebook_prompt_block())

mk_user <- function(ch) paste0(
  "Code each of the following ", nrow(ch), " comments. Copy each id exactly.\n\n",
  paste(sprintf("### id: %s\nSUBREDDIT: r/%s\nTHREAD: %s\nREPLYING TO: %s\nCOMMENT: %s",
                ch$id, ch$subreddit, substr(ch$thread_slug, 1, 90),
                fifelse(is.na(ch$parent_text) | !nzchar(ch$parent_text),
                        "(top-level comment)", substr(ch$parent_text, 1, 400)),
                substr(ch$text, 1, 1800)), collapse = "\n\n"))

D[, batch := ceiling(seq_len(.N) / BATCH)]
chunks <- split(D, D$batch)
dir.create("data/cache/variants", recursive = TRUE, showWarnings = FALSE)

## ---- scoring ----------------------------------------------------------------
macro_f1 <- function(truth, pred) {
  truth <- as.character(truth); pred <- as.character(pred)
  ok <- !is.na(truth) & !is.na(pred); truth <- truth[ok]; pred <- pred[ok]
  if (!length(truth)) return(NA_real_)
  lv <- sort(unique(truth))
  mean(vapply(lv, function(k) {
    tp <- sum(truth == k & pred == k); fp <- sum(truth != k & pred == k)
    fn <- sum(truth == k & pred != k)
    if (tp == 0) return(0)
    p <- tp/(tp+fp); r <- tp/(tp+fn); 2*p*r/(p+r)
  }, numeric(1)))
}

res <- list()
for (V in VARIANTS) {
  key <- KEYS[((V$key - 1) %% length(KEYS)) + 1]
  cat(sprintf("\n[S6] variant %s (%s, effort=%s, key %d)\n", V$tag, V$model, V$effort, V$key))
  chat <- chat_openai_compatible(
    base_url = "https://api.groq.com/openai/v1", system_prompt = sys, model = V$model,
    credentials = function() list(Authorization = paste("Bearer", key)),
    api_args = list(reasoning_effort = V$effort, temperature = 0), echo = "none")

  out <- list(); t0 <- Sys.time(); nfail <- 0L
  for (ci in seq_along(chunks)) {
    ch <- chunks[[ci]]
    cf <- file.path("data/cache/variants",
                    paste0(as.character(md5(paste(V$tag, paste(ch$id, collapse = ",")))), ".rds"))
    if (file.exists(cf)) { r <- readRDS(cf) } else {
      r <- tryCatch(chat$chat_structured(mk_user(ch), type = schema),
                    error = function(e) { message("  batch ", ci, ": ", conditionMessage(e)); NULL })
      if (!is.null(r)) saveRDS(r, cf) else nfail <- nfail + 1L
    }
    if (is.null(r) || is.null(r$results)) next
    dt <- if (is.data.frame(r$results)) as.data.table(r$results)
          else rbindlist(lapply(r$results, as.data.table), fill = TRUE)
    if (!nrow(dt)) next
    if (!"id" %in% names(dt) || !all(dt$id %in% ch$id)) dt[, id := ch$id[seq_len(.N)]]
    out[[length(out) + 1L]] <- dt
  }
  mins <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  if (!length(out)) { cat("  no usable output\n"); next }
  P <- unique(rbindlist(out, fill = TRUE), by = "id")
  present <- intersect(INCIV, names(P))
  P[, any_incivility := rowSums(as.matrix(.SD)) > 0, .SDcols = present]
  M <- merge(D[, .(id, h_rel = relevance, h_st = stance, h_inc = any_incivility)],
             P, by = "id")
  res[[V$tag]] <- data.table(
    variant = V$tag, model = V$model, effort = V$effort,
    n_scored = nrow(M), failed_batches = nfail, minutes = round(mins, 1),
    f1_relevance  = macro_f1(M$h_rel, M$relevance),
    f1_stance     = macro_f1(M$h_st,  M$stance),
    f1_incivility = macro_f1(ifelse(M$h_inc, "yes", "no"),
                             ifelse(M$any_incivility, "yes", "no")))
  print(res[[V$tag]])
}

R <- rbindlist(res, fill = TRUE)
R[, mean_f1 := round(rowMeans(.SD, na.rm = TRUE), 3),
  .SDcols = c("f1_relevance", "f1_stance", "f1_incivility")]
fc <- c("f1_relevance", "f1_stance", "f1_incivility")
R[, (fc) := lapply(.SD, round, 3), .SDcols = fc]
setorder(R, -mean_f1)
fwrite(R, "output/tables/variant_experiment.csv")
cat("\n[S6] VARIANT COMPARISON (dev split, n = 210, human-coded)\n")
print(R)
cat("\n[S6] the winner is frozen as the production annotator; the test split is untouched.\n")
