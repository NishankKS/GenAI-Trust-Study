## Diagnostic: how many cached batches came back incomplete?
##
## Each request sends 8 comments and should return 8 annotations. A response cut
## short by the completion-token ceiling still parses as valid JSON, so a short
## batch is silently lost rather than raised as an error -- worth measuring
## explicitly before trusting the label counts.
setwd("D:/GERMANY/NOTES/R")
args <- commandArgs(trailingOnly = TRUE)
dir  <- if (length(args)) args[1] else "data/cache/openai_gpt-oss-120b"

f <- list.files(dir, pattern = "[.]rds$", full.names = TRUE)
## results comes back either as a data.frame (one ROW per comment) or as a list
## of records. length() on a data.frame returns its COLUMN count, which is why an
## earlier version of this check reported 174% completeness -- it was counting
## the 14 schema fields, not the 8 annotations.
n <- vapply(f, function(x) {
  r <- tryCatch(readRDS(x)$result, error = function(e) NULL)
  if (!is.list(r) || is.null(r$results)) return(0L)
  if (is.data.frame(r$results)) nrow(r$results) else length(r$results)
}, integer(1))

cat(sprintf("%s\n", dir))
cat(sprintf("  cached batches            : %d\n", length(n)))
cat(sprintf("  annotations if all complete: %d\n", 8 * length(n)))
cat(sprintf("  annotations actually held  : %d  (%.1f%%)\n",
            sum(n), 100 * sum(n) / max(1, 8 * length(n))))
cat(sprintf("  incomplete batches         : %d  (%.1f%%)\n",
            sum(n < 8), 100 * mean(n < 8)))
cat("  results per batch:\n")
print(table(n))
