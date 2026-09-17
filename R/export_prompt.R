## Dump the exact pass-A system prompt and one batch of items to disk, so a
## non-ellmer backend (the Claude Code CLI) can annotate the identical inputs
## and stay comparable with passes A/B/C.
suppressPackageStartupMessages({library(arrow); library(data.table)})
setwd("D:/GERMANY/NOTES/R"); source("R/codebook.R")
src <- readLines("R/04_llm_annotate.R")
i0 <- which(startsWith(src, "sys_full <- paste0"))[1]
i1 <- which(startsWith(src, "sys_policy <- paste0"))[1]
eval(parse(text = paste(src[i0:(i1-1)], collapse = "\n")))
writeLines(sys_full, "data/derived/prompt_sysfull.txt")
cat("system prompt chars:", nchar(sys_full), "\n")

samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
setorder(samp, id)
chunk <- samp[1:8]
parts <- vapply(seq_len(nrow(chunk)), function(k) {
  ctx <- chunk$parent_text[k]
  ctx <- if (is.na(ctx) || !nzchar(ctx)) "(top-level comment)" else substr(ctx, 1, 400)
  sprintf("### id: %s\nSUBREDDIT: r/%s\nTHREAD: %s\nREPLYING TO: %s\nCOMMENT: %s",
          chunk$id[k], chunk$subreddit[k], substr(chunk$thread_slug[k], 1, 90),
          ctx, substr(chunk$text[k], 1, 1800))
}, character(1))
user <- paste0("Code each of the following ", nrow(chunk),
               " comments. Return one result per comment, with the id copied exactly.\n\n",
               paste(parts, collapse = "\n\n"))
writeLines(user, "data/derived/prompt_batch1.txt")
cat("user block chars:", nchar(user), "\n")

## Valid levels per field, so the CLI backend can reject an out-of-codebook
## label instead of silently writing it into the labels table. ellmer enforced
## this with type_enum; the CLI has no schema enforcement, so validation moves
## into the driver.
lv <- list()
for (f in c("relevance","stance","dimension","target","incivility_direction"))
  lv[[f]] <- cb_levels(f)
lv[["incivility_fields"]] <- cb_levels("incivility")
jsonlite::write_json(lv, "data/derived/codebook_levels.json", auto_unbox = TRUE)
cat("levels written\n")
