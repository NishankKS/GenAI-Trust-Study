## ---------------------------------------------------------------------------
## Delete cached batches that came back SHORT, so they are re-fetched.
##
## A response cut off by the completion-token ceiling still parses as valid JSON,
## so a short batch was cached as a success and its missing comments vanished
## silently. Pass A lost ~800 annotations that way before the ceiling was raised
## and truncation detection added.
##
## Their cache keys are unchanged, so the workers will never revisit them on
## their own. Removing the short files is what puts them back in the queue.
##
## Usage:  Rscript R/refetch_truncated.R [cache_dir] [--delete]
##         (dry run unless --delete is given)
## ---------------------------------------------------------------------------
setwd("D:/GERMANY/NOTES/R")
args <- commandArgs(trailingOnly = TRUE)
dir  <- if (length(args) && !startsWith(args[1], "--")) args[1] else
          "data/cache/openai_gpt-oss-120b"
do_del <- "--delete" %in% args
EXPECT <- 8L

f <- list.files(dir, pattern = "[.]rds$", full.names = TRUE)
n <- vapply(f, function(x) {
  r <- tryCatch(readRDS(x)$result, error = function(e) NULL)
  if (!is.list(r) || is.null(r$results)) return(0L)
  if (is.data.frame(r$results)) nrow(r$results) else length(r$results)
}, integer(1))

short <- f[n < EXPECT]
cat(sprintf("cache dir : %s\n", dir))
cat(sprintf("batches   : %d\n", length(f)))
cat(sprintf("complete  : %d\n", sum(n == EXPECT)))
cat(sprintf("SHORT     : %d  (holding %d of %d expected annotations)\n",
            length(short), sum(n[n < EXPECT]), length(short) * EXPECT))
cat(sprintf("recoverable annotations: %d\n",
            length(short) * EXPECT - sum(n[n < EXPECT])))

if (do_del) {
  file.remove(short)
  cat(sprintf("\nDELETED %d short batches -- they are now outstanding and will be re-fetched.\n",
              length(short)))
  cat(sprintf("pass A cache now holds %d/625 batches\n",
              length(list.files(dir, pattern = "[.]rds$"))))
} else {
  cat("\nDRY RUN. Re-run with --delete to remove them.\n")
}
