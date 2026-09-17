## ---------------------------------------------------------------------------
## Which sampled comments have no pass-A annotation yet?
##
## Rather than re-running whole truncated batches, collect only the comment ids
## that are actually missing and re-batch them into fresh full groups. A batch
## that returned 3 of 8 needs 5 comments re-requested, not 8 -- and pooling the
## missing ids across all short batches packs them back into complete batches of
## 8, so 803 missing annotations cost ~101 calls instead of 209.
##
## Merging is automatic: the assemble step unions every cached batch and dedupes
## by id, and a repair batch groups different ids so it gets its own cache key
## and cannot collide with the original.
##
## Usage: Rscript R/find_missing.R [pass]      (default A)
## Out:   data/derived/missing_ids_<pass>.csv
## ---------------------------------------------------------------------------
suppressPackageStartupMessages({library(arrow); library(data.table)})
setwd("D:/GERMANY/NOTES/R")
args <- commandArgs(trailingOnly = TRUE)
PASS <- if (length(args)) toupper(args[1]) else "A"
dir  <- switch(PASS,
  A = "data/cache/openai_gpt-oss-120b",
  B = "data/cache/qwen_qwen3_8-27b",
  C = "data/cache/openai_gpt-oss-safeguard-20b")

samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
if (!"eligible" %in% names(samp)) samp[, eligible := TRUE]
want <- samp[eligible == TRUE, id]

## every id that appears in any cached batch's results
f <- list.files(dir, pattern = "[.]rds$", full.names = TRUE)
have <- unlist(lapply(f, function(x) {
  r <- tryCatch(readRDS(x), error = function(e) NULL)
  if (is.null(r) || is.null(r$result$results)) return(NULL)
  res <- r$result$results
  ids <- if (is.data.frame(res)) res$id else vapply(res, function(z) z$id %||% NA_character_, character(1))
  ## the model is told to copy ids; fall back to the batch's own id list
  if (is.null(ids) || anyNA(ids) || !all(ids %in% r$ids)) r$ids[seq_along(ids)] else ids
}), use.names = FALSE)
`%||%` <- function(a, b) if (is.null(a)) b else a

miss <- setdiff(want, unique(have))
cat(sprintf("pass %s\n", PASS))
cat(sprintf("  sampled (eligible) : %d\n", length(want)))
cat(sprintf("  annotated          : %d\n", length(unique(have))))
cat(sprintf("  MISSING            : %d  -> %d repair calls at 8 per batch\n",
            length(miss), ceiling(length(miss) / 8)))

out <- data.table(id = miss)
fwrite(out, sprintf("data/derived/missing_ids_%s.csv", PASS))
cat(sprintf("  written: data/derived/missing_ids_%s.csv\n", PASS))
