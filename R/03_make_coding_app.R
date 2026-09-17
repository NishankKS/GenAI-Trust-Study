## ---------------------------------------------------------------------------
## S3b -- CODING INSTRUMENT
##
## Generates one self-contained HTML coding sheet per coder from the codebook
## and the gold sample. Open the file directly in a browser; it stores progress
## in localStorage and exports a CSV.
##
## Two separate files with independent storage keys is what makes the coding
## independent -- neither coder can see the other's decisions, which is the
## precondition for a meaningful reliability coefficient.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({library(data.table); library(jsonlite)})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")

CODERS <- c("UM", "NK")   # Utkarsh Midha, Nishank Kallollu Satish Kumar
dir.create("coding", showWarnings = FALSE)

gold <- fread("data/derived/gold_sample.csv")
gold[, parent_text := substr(fifelse(is.na(parent_text), "", parent_text), 1, 600)]
gold[, thread_slug := substr(thread_slug, 1, 90)]

items <- toJSON(gold[, .(id, subreddit, thread_slug, text, parent_text)],
                auto_unbox = TRUE)

## the form schema is derived from the codebook, not hand-written
fields <- c("relevance", "stance", "dimension", "target",
            "incivility", "incivility_direction")
schema <- lapply(fields, function(f) {
  cb <- CODEBOOK[[f]]
  list(field = f,
       label = cb$label,
       question = cb$question,
       multi = f == "incivility",
       levels = lapply(names(cb$levels), function(lv)
         list(name = lv, def = cb$levels[[lv]]$def)))
})
schema_json <- toJSON(schema, auto_unbox = TRUE)

tpl <- paste(readLines("docs/coder_template.html", warn = FALSE), collapse = "\n")
for (cd in CODERS) {
  h <- gsub("__CODER__", cd, tpl, fixed = TRUE)
  h <- sub("/*__DATA__*/", items, h, fixed = TRUE)
  h <- sub("/*__SCHEMA__*/", schema_json, h, fixed = TRUE)
  f <- file.path("coding", sprintf("coder_%s.html", cd))
  writeLines(h, f, useBytes = TRUE)
  cat(sprintf("[S3b] %s  (%d items, %.0f KB)\n", f, nrow(gold), file.size(f) / 1024))
}
