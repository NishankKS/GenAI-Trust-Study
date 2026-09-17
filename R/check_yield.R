## Items-per-batch yield for a pass, split by cache-file mtime.
##
## Pass A truncated at the old max_tokens ceiling and silently dropped the tail
## of every batch, so raw batch counts overstate progress. This reads the cached
## results directly and reports mean items per 8-item batch, before and after a
## cutoff time, which is how the fix is verified.
##
## Usage: Rscript R/check_yield.R <cache_dir> <cutoff "YYYY-MM-DD HH:MM:SS">
args <- commandArgs(trailingOnly = TRUE)
dir  <- args[1]
cut  <- as.POSIXct(args[2])

f    <- list.files(dir, "[.]rds$", full.names = TRUE)
mt   <- file.info(f)$mtime
cnt  <- function(p) {
  x <- tryCatch(readRDS(p), error = function(e) NULL)
  ## A cache entry is list(ids = <the 8 requested>, result = list(results = tbl)).
  ## The tbl holds only the items the model actually returned, so its row count
  ## is the yield for that batch.
  r <- x$result$results
  if (is.null(x) || is.null(r) || length(nrow(r)) != 1L) NA_integer_
  else as.integer(nrow(r))
}
n_old <- vapply(f[mt <= cut], cnt, integer(1))
n_new <- vapply(f[mt >  cut], cnt, integer(1))

cat(sprintf("before %s : %4d batches, mean %.2f items/batch\n",
            format(cut, "%H:%M:%S"), length(n_old), mean(n_old, na.rm = TRUE)))
cat(sprintf("after  %s : %4d batches, mean %.2f items/batch\n",
            format(cut, "%H:%M:%S"), length(n_new), mean(n_new, na.rm = TRUE)))
if (length(n_new)) cat("after sizes:", paste(sort(n_new), collapse = ","), "\n")
