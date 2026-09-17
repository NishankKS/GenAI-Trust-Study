## ---------------------------------------------------------------------------
## S4b -- SELF-CONSISTENCY ESCALATION
##
## Where the two model families disagree, a single extra opinion would just be a
## third vote of unknown quality. Instead each disputed comment is re-annotated
## k = 3 times at temperature 0.7 by the primary annotator and resolved by
## majority vote -- self-consistency sampling. Comments where even that fails to
## produce a majority are flagged for human adjudication rather than guessed at.
##
## This is what turns "the models disagreed" from noise into a resolved
## measurement, and it is applied ONLY to the disputed band, which is what makes
## it affordable: roughly a quarter of the sample, times three, instead of the
## whole sample times three.
##
## Usage:  Rscript R/04b_selfconsistency.R [max_requests] [key_index]
## In:     data/derived/disagreements.csv   (written by R/09_validate.R)
## Out:    data/derived/selfconsistency.parquet
##         output/tables/selfconsistency_summary.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(ellmer); library(arrow); library(data.table); library(openssl)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")

args    <- commandArgs(trailingOnly = TRUE)
MAX_REQ <- as.integer(if (length(args) >= 1) args[1] else 400L)
KEY_IDX <- as.integer(if (length(args) >= 2) args[2] else 1L)
K       <- 3L        # samples per comment
TEMP    <- 0.7
BATCH   <- 8L
MODEL   <- "openai/gpt-oss-120b"
RPM     <- 2L

KEYS <- trimws(readLines(if (file.exists("groq_keys.txt")) "groq_keys.txt" else "groq api.txt",
                         warn = FALSE))
KEYS <- KEYS[nzchar(KEYS) & !startsWith(KEYS, "#")]
api_key <- KEYS[((KEY_IDX - 1) %% length(KEYS)) + 1]
cache_dir <- "data/cache/selfconsistency"
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists("data/derived/disagreements.csv"))
  stop("no disagreements file -- run R/09_validate.R first")
dis <- fread("data/derived/disagreements.csv")
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
D <- merge(dis, samp[, .(id, text, subreddit, thread_slug, parent_text)], by = "id")
setorder(D, id)
cat(sprintf("[S4b] %s disputed comments, k = %d, temperature %.1f -> %d requests\n",
            format(nrow(D), big.mark = ","), K, TEMP,
            ceiling(nrow(D) / BATCH) * K))

## ---- schema and prompt: identical to the production pass ---------------------
INCIV <- cb_levels("incivility")
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
2. Quoted text, code blocks and URLs were removed before you see the comment, so every
   word is the commenter's own. Do not excuse incivility as quotation.
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
batches <- split(D, D$batch)
cf <- function(b, k) file.path(cache_dir,
  paste0(as.character(md5(paste(MODEL, "sc", k, paste(b$id, collapse = ",")))), ".rds"))

new_chat <- function() chat_openai_compatible(
  base_url = "https://api.groq.com/openai/v1", system_prompt = sys, model = MODEL,
  credentials = function() list(Authorization = paste("Bearer", api_key)),
  api_args = list(reasoning_effort = "medium", temperature = TEMP), echo = "none")

n_ok <- 0L; t0 <- Sys.time()
outer_loop <- TRUE
for (k in seq_len(K)) {
  if (!outer_loop) break
  for (b in batches) {
    f <- cf(b, k)
    if (file.exists(f)) next
    if (n_ok >= MAX_REQ) { cat("[S4b] quota guard reached\n"); outer_loop <- FALSE; break }
    r <- tryCatch(new_chat()$chat_structured(mk_user(b), type = schema), error = function(e) e)
    if (inherits(r, "condition")) {
      if (grepl("tokens per day|TPD", conditionMessage(r), ignore.case = TRUE)) {
        cat("[S4b] daily token budget exhausted -- stopping cleanly\n")
        outer_loop <- FALSE; break
      }
      next
    }
    saveRDS(list(ids = b$id, result = r, k = k), f)
    n_ok <- n_ok + 1L
    if (n_ok %% 10 == 0)
      cat(sprintf("[S4b] %d requests | %.1f min\n", n_ok,
                  as.numeric(difftime(Sys.time(), t0, units = "mins"))))
    Sys.sleep(max(0, 60 / RPM - 2))
  }
}

## ---- majority vote -----------------------------------------------------------
rows <- list()
for (k in seq_len(K)) for (b in batches) {
  f <- cf(b, k); if (!file.exists(f)) next
  r <- readRDS(f)$result
  dt <- if (is.data.frame(r$results)) as.data.table(r$results)
        else rbindlist(lapply(r$results, as.data.table), fill = TRUE)
  if (!nrow(dt)) next
  if (!"id" %in% names(dt) || !all(dt$id %in% b$id)) dt[, id := b$id[seq_len(.N)]]
  dt[, draw := k]
  rows[[length(rows) + 1L]] <- dt[, .(id, draw, stance = as.character(stance))]
}
if (!length(rows)) { cat("[S4b] nothing to vote on yet\n"); quit(save = "no") }

V <- rbindlist(rows)
votes <- V[, .N, by = .(id, stance)]
setorder(votes, id, -N)
res <- votes[, {
  top <- N[1]; tied <- sum(N == top) > 1
  .(sc_stance = if (tied) NA_character_ else stance[1],
    votes_for = top, n_draws = sum(N), tie = tied)
}, by = id]

write_parquet(res, "data/derived/selfconsistency.parquet", compression = "zstd")
summ <- data.table(
  disputed_comments = nrow(D),
  resolved          = sum(!is.na(res$sc_stance)),
  unresolved_ties   = sum(res$tie),
  unanimous         = sum(res$votes_for == res$n_draws & !res$tie),
  requests_sent     = n_ok)
fwrite(summ, "output/tables/selfconsistency_summary.csv")
cat("\n[S4b] resolution of the disputed band\n"); print(summ)
if (sum(res$tie))
  cat(sprintf("[S4b] %d ties remain -- these go to human adjudication, not a coin flip\n",
              sum(res$tie)))
