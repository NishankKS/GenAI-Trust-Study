## ---------------------------------------------------------------------------
## Trust, Incivility and Public Perceptions of Generative AI in Online Discussions
## Utkarsh Midha (5553189) - Nishank Kallollu Satish Kumar (5522886)
##
## Reproduction driver. Run from the project root.
##
##   Rscript run_all.R
##
## Stages S0-S4 are implemented. Each writes its outputs to data/ and output/
## and is safe to re-run: the ingest overwrites, the sampling is seeded, and
## the LLM annotation is cached per batch so repeats cost no API quota.
##
## Prerequisites
##   R 4.5.x with: arrow, data.table, stringi, jsonlite, ellmer, openssl, irr
##   Python 3.12 with: duckdb, pandas          (S0 ingest only)
##   A Groq API key in "groq api.txt"          (S4 only)
## ---------------------------------------------------------------------------

stopifnot(file.exists("R/codebook.R"))
t_start <- Sys.time()

run <- function(what, cmd) {
  cat("\n", strrep("=", 72), "\n", what, "\n", strrep("=", 72), "\n", sep = "")
  st <- system(cmd)
  if (st != 0) stop("failed: ", what)
}

## S0  ingest ---------------------------------------------------------------
## 2.3 GB of JSONL -> 120 MB of Parquet, plus resolved reply depth.
run("S0  ingest raw JSONL to Parquet", "python R/00_ingest.py")

## S1  corpus ---------------------------------------------------------------
## Window, bot removal, text normalisation (quote-stripping matters), language
## filter, high-recall lexical relevance prefilter, features. Writes the
## exclusion funnel.
run("S1  build and clean the analysis corpus", "Rscript R/01_corpus.R")

## S2/S3  codebook and sampling ---------------------------------------------
## One stratified probability sample with recorded inclusion probabilities;
## the human gold set is a random subsample of it, which is what makes the
## design-based correction in S9 valid. Also renders docs/codebook.md.
run("S3  sampling design and codebook", "Rscript R/02_sample.R")
run("S3b generate the coding instruments", "Rscript R/03_make_coding_app.R")

## S4  LLM annotation -------------------------------------------------------
## Quota guard: Groq free tier allows 1,000 requests/day and 8,000 tokens/min,
## so the three passes are spread across days. Cached batches are never resent.
##   A  openai/gpt-oss-120b          primary annotator     ~625 requests
##   C  openai/gpt-oss-safeguard-20b policy classifier     ~625 requests
##   B  qwen/qwen3.8-27b             second annotator      ~235 requests
run("S4A primary LLM annotation", "Rscript R/04_llm_annotate.R A 900")
## run on subsequent days, or when quota allows:
## run("S4C policy-conditioned incivility", "Rscript R/04_llm_annotate.R C 900")
## run("S4B second-family annotation",      "Rscript R/04_llm_annotate.R B 900")

cat(sprintf("\nall stages finished in %.1f min\n",
            as.numeric(difftime(Sys.time(), t_start, units = "mins"))))
writeLines(capture.output(sessionInfo()), "output/sessionInfo.txt")
