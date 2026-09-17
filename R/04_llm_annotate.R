## ---------------------------------------------------------------------------
## S4 -- LLM ANNOTATION AS A MEASURED INSTRUMENT
##
## Not "we asked an LLM". A versioned, cached, quota-aware measurement
## procedure whose output is scored against the human gold standard in S6.
##
## Three passes, deliberately from different model families so that agreement
## between them carries information:
##   A  openai/gpt-oss-120b         primary annotator, all constructs
##   B  qwen/qwen3.8-27b            independent second annotator (subsample)
##   C  openai/gpt-oss-safeguard-20b  policy-conditioned incivility classifier:
##                                  our own codebook IS the policy, which is the
##                                  answer to the construct-validity objection
##                                  against off-the-shelf toxicity APIs.
##
## Usage:  Rscript R/04_llm_annotate.R A [max_requests] [n_items]
##
## Every batch response is cached on disk under a hash of
## (model, prompt version, item ids), so an interrupted or repeated run costs
## zero API quota. With a hard ceiling of 1,000 requests per day this is not a
## convenience, it is the only way the study fits in the budget.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(ellmer); library(arrow); library(data.table); library(openssl)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")

PROMPT_VERSION <- "v5-full-codebook-b8"
BATCH          <- 8L
args           <- commandArgs(trailingOnly = TRUE)
PASS           <- toupper(if (length(args) >= 1) args[1] else "A")
MAX_REQ        <- as.integer(if (length(args) >= 2) args[2] else 900L)
N_ITEMS        <- as.integer(if (length(args) >= 3) args[3] else NA)
SHARD          <- as.integer(if (length(args) >= 4) args[4] else 1L)   # 1-based
N_SHARDS       <- as.integer(if (length(args) >= 5) args[5] else 1L)
REASONING      <- if (length(args) >= 6) args[6] else "medium"
MAX_WAIT       <- 240     # seconds; a request is abandoned past this
## Completion ceiling; see the api_args note below. Pass A needs far more room
## than B or C because gpt-oss-120b's reasoning tokens count toward the
## completion, and at 2,400 it truncated the tail off 29% of every batch.
## Overridable as arg 9 so this can be retuned without editing the file.
## Measured completion for a batch of 8 is ~1,866 tokens, so 3,000 is 61% of
## headroom above typical -- and a batch that still runs long is now DETECTED
## and retried at double the ceiling rather than silently truncated. The leaner
## ceiling matters because Groq reserves prompt + max_tokens against both the
## per-minute bucket and the daily budget: 3,000 reserves ~5,100 instead of
## ~6,900, which is 35% more requests per key per day at identical quality.
MAX_TOK         <- as.integer(if (length(args) >= 9) args[9] else
                              if (PASS == "A") 3000L else 2400L)
## Pacing, set from a measured request rather than a guess. A batch of 8 costs
## 3,847 tokens (2,055 prompt + 1,792 completion) and RESERVES prompt +
## max_tokens = 4,455 against the per-minute bucket. That bucket is 8,000 PER
## KEY, so 8000/4455 = 1.80 requests/minute/key is the hard ceiling, and each key
## has its own bucket and its own remaining daily budget. Target 1.65 to leave
## headroom for longer prompts.
## Derive the rate from the reservation instead of hard-coding it. Groq counts
## prompt + max_tokens against the per-minute bucket, so raising MAX_TOK lowers
## how many requests a key can take -- and the two were set independently, which
## is how pass A ended up targeting 1.65/min against a real ceiling of 1.16 and
## spending its time in backoffs. Measured prompt is ~2,075 tokens; 95% of the
## resulting ceiling leaves margin for longer ones.
PROMPT_TOKENS   <- 2100
TARGET_RATE     <- as.numeric(if (length(args) >= 8) args[8] else
                              0.95 * 8000 / (PROMPT_TOKENS + MAX_TOK))
TARGET_INTERVAL <- 60 / TARGET_RATE

## ADAPTIVE PACING. The fixed interval above is derived from what the token
## reservation *should* allow, but the only way to know a key's real limit is to
## push it and watch. So each worker starts aggressive and lets its key tell it
## the rate: a refusal or timeout multiplies the interval, a run of successes
## shaves it back down. Every key adapts independently, so a key with plenty of
## headroom runs fast while a tight one backs off, instead of all six being held
## to the slowest.
INTERVAL_START <- 20      # seconds -- 3/min, deliberately above the theoretical rate
INTERVAL_MIN   <- 12      # never hammer faster than this
INTERVAL_MAX   <- 180     # never crawl slower than this
BACKOFF_MULT   <- 1.6     # on refusal / timeout
SPEEDUP_MULT   <- 0.90    # per consecutive success
SPEEDUP_AFTER  <- 2       # successes needed before speeding up again
interval  <- INTERVAL_START
ok_streak <- 0L
## Which key this worker uses. Defaults to the shard index, but is separable so
## that a slow pass can be handed keys the other passes are not using -- the
## 120b model at medium reasoning effort costs roughly three times the tokens
## per request that the 27b and 20b models do, and needs the extra capacity.
KEY_IDX        <- as.integer(if (length(args) >= 7) args[7] else SHARD)

MODEL <- switch(PASS,
  A = "openai/gpt-oss-120b",
  B = "qwen/qwen3.8-27b",
  C = "openai/gpt-oss-safeguard-20b",
  stop("pass must be A, B or C"))

## Multi-key throughput. Groq's free tier caps each key at 1,000 requests/day
## and 8,000 tokens/minute; tokens are the binding constraint. Additional keys
## from separate accounts are independent buckets, so N keys run as N shards of
## the batch list in parallel and cut wall-clock time by a factor of N.
## Put one key per line in groq_keys.txt (falls back to "groq api.txt").
keyfile <- if (file.exists("groq_keys.txt")) "groq_keys.txt" else "groq api.txt"
KEYS <- trimws(readLines(keyfile, warn = FALSE))
KEYS <- KEYS[nzchar(KEYS) & !startsWith(KEYS, "#")]
if (!length(KEYS)) stop("no API keys found in ", keyfile)
if (N_SHARDS > length(KEYS))
  stop(sprintf("asked for %d shards but only %d key(s) in %s", N_SHARDS, length(KEYS), keyfile))
api_key <- KEYS[((KEY_IDX - 1) %% length(KEYS)) + 1]
cat(sprintf("[S4-%s] shard %d/%d using key %d of %d (...%s)\n",
            PASS, SHARD, N_SHARDS, ((KEY_IDX - 1) %% length(KEYS)) + 1, length(KEYS),
            substr(api_key, nchar(api_key) - 5, nchar(api_key))))
cache_dir <- file.path("data/cache", gsub("[/.]", "_", MODEL))
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

## ---- items ---------------------------------------------------------------
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
setorder(samp, id)
if (!is.na(N_ITEMS)) samp <- samp[seq_len(min(N_ITEMS, .N))]

## REPAIR MODE (arg 10 = "repair"): work only the comments that have no
## annotation yet, re-batched into fresh full groups of 8. A truncated batch
## that returned 3 of 8 needs its 5 missing comments re-requested, not all 8 --
## pooling the gaps across batches turns 209 partial re-runs into ~101 full
## ones. The new grouping produces new cache keys, so repaired batches sit
## alongside the originals and the assemble step unions them and dedupes by id.
REPAIR <- length(args) >= 10 && tolower(args[10]) == "repair"
if (REPAIR) {
  mf <- sprintf("data/derived/missing_ids_%s.csv", PASS)
  if (!file.exists(mf)) stop("repair mode needs ", mf, " -- run R/find_missing.R first")
  miss <- fread(mf)$id
  samp <- samp[id %in% miss]
  cat(sprintf("[S4-%s] REPAIR MODE: %s missing comments -> %d batches
",
              PASS, format(nrow(samp), big.mark = ","), ceiling(nrow(samp) / BATCH)))
}
cat(sprintf("[S4-%s] %s | %s items | prompt %s\n", PASS, MODEL,
            format(nrow(samp), big.mark = ","), PROMPT_VERSION))

## ---- response schema ------------------------------------------------------
## Built from the codebook, so the model is structurally incapable of
## returning a label that is not in the coding scheme.
inciv_fields <- cb_levels("incivility")
one_result <- function(full = TRUE) {
  f <- list(
    .description = "Annotation of one comment",
    .additional_properties = FALSE,
    id = type_string("The exact id string given for this comment."))
  if (full) f <- c(f, list(
    relevance = type_enum(cb_levels("relevance"), "Relevance gate."),
    stance    = type_enum(cb_levels("stance"), "Trust stance toward the AI target."),
    dimension = type_enum(cb_levels("dimension"), "Most prominent trust dimension."),
    target    = type_enum(cb_levels("target"), "What the stance is directed at.")))
  for (nm in inciv_fields)
    f[[nm]] <- type_boolean(sprintf("TRUE if the comment contains %s.", nm))
  f$incivility_direction <- type_enum(cb_levels("incivility_direction"),
                                      "Who the incivility is aimed at; 'none' if civil.")
  f$confidence <- type_number("Your confidence in this annotation, 0 to 1.")
  do.call(type_object, f)
}
schema <- type_object(
  .additional_properties = FALSE,
  results = type_array(one_result(full = PASS != "C"),
                       "One entry per comment, in the order given."))

## ---- prompts --------------------------------------------------------------
sys_full <- paste0(
"You are an expert content analyst coding Reddit comments for a communication-science
study of trust and incivility in discussions about generative AI. You apply the codebook
below exactly as written. You are not giving your opinion about AI; you are recording
what each comment expresses.

RULES
1. Code only what the comment itself says. Do not infer unstated beliefs.
2. Quoted text, code blocks and URLs were removed before you see the comment, so every
   word is the commenter's own. Do not excuse incivility as quotation.
3. Sarcasm and irony carry their intended meaning, not their literal one.
4. Criticising an AI system is DISTRUST, not automatically incivility. Incivility is a
   violation of discussion norms, and it can be aimed at a system, a company or a person.
5. If relevance is not_relevant, set stance to non_evaluative and dimension and target to
   not_applicable. Incivility is still coded for every comment, relevant or not.
6. Think briefly before answering, then return only the structured result.

CODEBOOK
", codebook_prompt_block())

## Pass C reframes the same codebook as a policy document, which is the mode
## gpt-oss-safeguard is trained for.
sys_policy <- paste0(
"You are a policy classifier. Below is a POLICY defining uncivil communication for a
communication-science study. Apply the policy exactly as written to each comment and
report which policy categories the comment violates.

The policy is definitional, not moral: your task is measurement, not moderation. Quoted
text has been stripped, so all words are the commenter's own. Criticising an AI system's
quality is not by itself a violation; hostility, insult, contempt, accusation of bad
faith, identity attack or threat are.

POLICY
", codebook_prompt_block(c("incivility", "incivility_direction")))

make_user <- function(chunk) {
  parts <- vapply(seq_len(nrow(chunk)), function(k) {
    ctx <- chunk$parent_text[k]
    ctx <- if (is.na(ctx) || !nzchar(ctx)) "(top-level comment)" else
             substr(ctx, 1, 400)
    sprintf("### id: %s\nSUBREDDIT: r/%s\nTHREAD: %s\nREPLYING TO: %s\nCOMMENT: %s",
            chunk$id[k], chunk$subreddit[k], substr(chunk$thread_slug[k], 1, 90),
            ctx, substr(chunk$text[k], 1, 1800))
  }, character(1))
  paste0("Code each of the following ", nrow(chunk),
         " comments. Return one result per comment, with the id copied exactly.\n\n",
         paste(parts, collapse = "\n\n"))
}

## ---- batching and cache ---------------------------------------------------
samp[, batch := ceiling(seq_len(.N) / BATCH)]
batches <- split(samp, samp$batch)
key_of <- function(chunk) as.character(md5(paste(MODEL, PROMPT_VERSION, PASS,
                                                 paste(chunk$id, collapse = ","))))
cache_file <- function(k) file.path(cache_dir, paste0(k, ".rds"))

## Work is claimed rather than statically sharded. Each worker repeatedly takes
## the next uncached, unclaimed batches, writes a short-lived claim file, sends
## them, then caches the result and releases the claim. Any number of workers on
## any number of keys can therefore run against the same pass at once, and a
## worker can be added mid-run as another pass finishes and frees its key --
## which matters because the 120b model at medium reasoning effort is roughly
## three times slower per request than the smaller two, and needs the capacity
## they release. A stale claim (a killed worker) expires and is retried.
claims_dir <- file.path(cache_dir, "_claims")
dir.create(claims_dir, recursive = TRUE, showWarnings = FALSE)
claim_file <- function(k) file.path(claims_dir, paste0(k, ".claim"))
CLAIM_TTL  <- 45 * 60          # seconds before another worker may retake a batch
CHUNK      <- 20L

n_cached <- sum(vapply(batches, function(ch) file.exists(cache_file(key_of(ch))), logical(1)))
cat(sprintf("[S4-%s] %d batches total | %d cached | %d outstanding
",
            PASS, length(batches), n_cached, length(batches) - n_cached))

take_work <- function(n) {
  out <- list()
  if (n < 1) return(out)          # MAX_REQ = 0 means "assemble from cache only"
  for (ch in batches) {
    k <- key_of(ch)
    if (file.exists(cache_file(k))) next
    cp <- claim_file(k)
    if (file.exists(cp) &&
        as.numeric(difftime(Sys.time(), file.mtime(cp), units = "secs")) < CLAIM_TTL) next
    ## Recreate the claims directory if it has gone missing. Workers for other
    ## passes share data/cache/, and a directory swept while this one is running
    ## would otherwise kill it mid-loop.
    if (!dir.exists(claims_dir)) dir.create(claims_dir, recursive = TRUE, showWarnings = FALSE)
    ok <- tryCatch({ writeLines(sprintf("%s pid=%d", format(Sys.time()), Sys.getpid()), cp); TRUE },
                   error = function(e) FALSE)
    if (!ok) next
    out[[length(out) + 1L]] <- ch
    if (length(out) >= n) break
  }
  out
}

## ---- send -----------------------------------------------------------------
## SEQUENTIAL, with the response cached the instant it arrives.
##
## This is not a stylistic choice. Groq's free tier caps each key at 200,000
## tokens per DAY per model (confirmed from a 429 body), which at 4,167 tokens a
## request is 48 requests per key per day. Under that ceiling, throughput is
## capped by the daily budget, not by concurrency, so batching requests into a
## parallel call buys nothing -- while any work in flight when a worker is
## interrupted is billed and then thrown away. Caching per request means an
## interruption costs at most one request.
##
## NOTE: ellmer 0.4.0's dedicated chat_groq() provider strips
## `additionalProperties: false` from nested schema objects, which Groq's strict
## structured-output mode requires -- every batched request fails with HTTP 400.
## Routing through the generic OpenAI-compatible provider fixes the schema. The
## Chat object also accumulates turn history, so a fresh one is built per
## request; reusing it grows the context until the request is rejected.
new_chat <- function() chat_openai_compatible(
  base_url = "https://api.groq.com/openai/v1",
  system_prompt = if (PASS == "C") sys_policy else sys_full,
  model = MODEL,
  credentials = function() list(Authorization = paste("Bearer", api_key)),
  ## max_tokens matters for more than truncation: Groq checks
  ## prompt_tokens + max_tokens against the REMAINING daily budget before running
  ## anything. With no max_tokens set, the model's large default is reserved, so a
  ## key still holding a few thousand tokens refuses a request it could actually
  ## have served -- which is why a pass could run on five keys and complete zero
  ## requests, so a smaller reservation lets a request through on a key that
  ## would otherwise refuse it.
  ##
  ## But 2,400 was calibrated on the 27b/20b models and is NOT safe for pass A.
  ## gpt-oss-120b at medium reasoning effort counts its reasoning tokens toward
  ## the completion, so a batch of 8 does not fit and the tail of the batch is
  ## simply never emitted. Measured over 307 cached A batches, the share of
  ## items returned falls monotonically by position -- item 1 100%, item 4 75%,
  ## item 8 42% -- for a yield of 5.65 of 8, i.e. 29% of pass A's budget bought
  ## nothing. That is a correctness bug, not just lost throughput: the labels
  ## that survive are the ones that happened to sit early in a batch.
  ##
  ## So the ceiling is per-pass, and overridable as arg 9 for retuning without
  ## touching this file. A gets room for 8 full items plus reasoning; B and C
  ## keep the value their own completions were measured against.
  api_args = list(reasoning_effort = REASONING, temperature = 0,
                  max_tokens = MAX_TOK),
  echo = "none")

## Pre-flight each request against this key's own daily budget.
##
## ellmer exposes no retry configuration, and when the daily budget is gone Groq
## answers with retry-after values of 15-20 minutes, which ellmer waits out
## internally. A worker that discovers exhaustion only AFTER the call returns
## therefore burns most of its window sitting in a backoff. This probe costs a
## couple of tokens and reserves just over one request's worth, so it fails
## precisely when the key can no longer serve a real request -- and the worker
## exits immediately, freeing the scheduler to move to a pass that can run.
##
## A per-MINUTE refusal is transient and is simply waited out; only a per-DAY
## refusal ends the worker.
budget_state <- function() {
  ## Groq compares (prompt_tokens + max_tokens) against the remaining daily
  ## budget, so what matters is the RESERVATION, not the prompt. A two-token
  ## prompt with max_tokens = 4700 reserves the same ~4,700 a real request does
  ## (2,305 prompt + 2,400 completion) while costing a couple of tokens when it
  ## passes. An earlier version padded the prompt to 1,700 words to match the
  ## reservation, which meant every probe -- one per work item, per worker --
  ## burned ~2,200 tokens of the very budget it was meant to protect.
  body <- list(model = MODEL,
               messages = list(list(role = "user", content = "ok")),
               ## Reserve exactly what a real request reserves. Hard-coding this
               ## at 4,700 while requests moved to prompt + 4,800 = ~6,900 made
               ## the probe systematically optimistic by ~2,200 tokens per key:
               ## keys reported AVAILABLE, then refused the request and parked
               ## the worker in a 15-minute backoff.
               max_tokens = as.integer(MAX_TOK))
  r <- tryCatch(
    httr2::request("https://api.groq.com/openai/v1/chat/completions") |>
      httr2::req_headers(Authorization = paste("Bearer", api_key)) |>
      httr2::req_body_json(body) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_retry(max_tries = 1) |>
      httr2::req_perform(),
    error = function(e) NULL)
  if (is.null(r)) return("unknown")
  if (httr2::resp_status(r) < 300) return("ok")
  msg <- tryCatch(httr2::resp_body_json(r)$error$message, error = function(e) "")
  if (grepl("per day", msg, ignore.case = TRUE)) return("day")
  if (grepl("per minute", msg, ignore.case = TRUE)) return("minute")
  "unknown"
}

t0 <- Sys.time(); n_ok <- 0L; n_err <- 0L; n_attempt <- 0L
n_timeout <- 0L; quota_hit <- FALSE
## Probe sparingly. The probe reserves ~4,700 tokens and the request that follows
## reserves ~4,705; back to back that is ~9,400 against an 8,000-per-MINUTE
## bucket, so probing before every request made the worker trip its own rate
## limit and sit in 800-1000 second backoffs while the DAILY budget was fully
## available. Probe on the first iteration, then only every PROBE_EVERY requests
## or immediately after a failure -- which is when the answer can actually have
## changed.
PROBE_EVERY <- 12L
need_probe <- TRUE

repeat {
  bs <- if (need_probe) budget_state() else "ok"
  need_probe <- FALSE
  if (bs == "day") {
    cat(sprintf("[S4-%s] daily budget gone on this key -- exiting without stalling
", PASS))
    quota_hit <- TRUE; break
  }
  if (bs == "minute") { Sys.sleep(20); next }

  work <- take_work(1L)
  if (!length(work)) break
  ch <- work[[1]]; k <- key_of(ch)
  n_attempt <- n_attempt + 1L
  ## ellmer retries a 429 internally, and when the daily budget is gone Groq
  ## returns retry-after values of 10-20 minutes. Rather than let a worker idle
  ## through those, a request that takes longer than MAX_WAIT is treated as
  ## budget exhaustion: the pass stops cleanly and resumes from cache later.
  ## The preflight above only proves the budget was there a moment ago; a request
  ## can still trip the limit mid-flight, and ellmer then waits out a 15-20 minute
  ## retry-after internally with no way to configure it away. setTimeLimit raises
  ## an R-level error out of that wait, so a worker can never be parked for longer
  ## than MAX_WAIT. The work item stays uncached and is retried later.
  t_req <- Sys.time()
  r <- tryCatch({
    setTimeLimit(elapsed = MAX_WAIT, transient = TRUE)
    on.exit(setTimeLimit(elapsed = Inf, transient = TRUE), add = TRUE)
    new_chat()$chat_structured(make_user(ch), type = schema)
  }, error = function(e) e)
  setTimeLimit(elapsed = Inf, transient = TRUE)
  waited <- as.numeric(difftime(Sys.time(), t_req, units = "secs"))
  if (inherits(r, "condition")) {
    msg <- conditionMessage(r)
    n_err <- n_err + 1L
    ## Congestion signal: this key just refused or stalled, so back off ON THIS
    ## KEY ONLY. The success streak resets, so the worker has to earn its speed
    ## back rather than snapping straight to the previous rate.
    interval  <- min(INTERVAL_MAX, interval * BACKOFF_MULT)
    ok_streak <- 0L
    ## A daily-token refusal is not a transient error: stop cleanly and let the
    ## next day's run resume from the cache rather than burning the retry budget.
    if (grepl("tokens per day|TPD", msg, ignore.case = TRUE)) {
      cat(sprintf("[S4-%s] daily token budget exhausted for %s on this key -- stopping
",
                  PASS, MODEL))
      quota_hit <- TRUE
      unlink(claim_file(k)); break
    }
    if (n_attempt <= 3 || n_attempt %% 10 == 0)
      cat(sprintf("[S4-%s] request failed: %s
", PASS, substr(msg, 1, 120)))
    ## A timed-out request is NOT proof the daily budget is gone -- a transient
    ## per-minute backoff produces exactly the same symptom. Treating the first
    ## timeout as exhaustion made every worker quit after a single attempt, which
    ## is why a pass with budget on all five keys completed only 1-4 requests per
    ## cycle. Ask the budget endpoint what actually happened, and stop only on a
    ## genuine per-day refusal.
    if (waited > MAX_WAIT) {
      bs2 <- budget_state()
      if (bs2 == "day") {
        cat(sprintf("[S4-%s] timeout confirmed as daily exhaustion -- stopping\n", PASS))
        quota_hit <- TRUE; break
      }
      n_timeout <- n_timeout + 1L
      cat(sprintf("[S4-%s] timeout (%s) -- transient, retrying (%d/8)\n",
                  PASS, bs2, n_timeout))
      if (n_timeout >= 8) {
        cat(sprintf("[S4-%s] 8 consecutive timeouts -- backing off this key\n", PASS))
        quota_hit <- TRUE; break
      }
      Sys.sleep(30)
    }
  } else if (is.list(r) && !is.null(r$results) && length(r$results)) {
    ## A response cut short by the completion ceiling still parses as valid
    ## JSON, so a short batch would be cached as a success and its missing
    ## comments lost silently -- that is how pass A quietly dropped 21% of its
    ## annotations. Count the results: if the batch is short it is retried once
    ## with a much larger ceiling, and only a complete batch is cached. This is
    ## what lets the normal ceiling stay lean without risking data loss.
    n_res <- if (is.data.frame(r$results)) nrow(r$results) else length(r$results)
    if (n_res < nrow(ch)) {
      cat(sprintf("[S4-%s] short batch (%d/%d) -- retrying with a larger ceiling
",
                  PASS, n_res, nrow(ch)))
      r2 <- tryCatch({
        setTimeLimit(elapsed = MAX_WAIT, transient = TRUE)
        on.exit(setTimeLimit(elapsed = Inf, transient = TRUE), add = TRUE)
        chat_openai_compatible(
          base_url = "https://api.groq.com/openai/v1",
          system_prompt = if (PASS == "C") sys_policy else sys_full,
          model = MODEL,
          credentials = function() list(Authorization = paste("Bearer", api_key)),
          api_args = list(reasoning_effort = REASONING, temperature = 0,
                          max_tokens = as.integer(MAX_TOK * 2)),
          echo = "none")$chat_structured(make_user(ch), type = schema)
      }, error = function(e) e)
      setTimeLimit(elapsed = Inf, transient = TRUE)
      if (is.list(r2) && !is.null(r2$results)) {
        n2 <- if (is.data.frame(r2$results)) nrow(r2$results) else length(r2$results)
        if (n2 > n_res) { r <- r2; n_res <- n2 }
      }
    }
    if (n_res < nrow(ch))
      cat(sprintf("[S4-%s] still short (%d/%d) after retry -- caching partial
",
                  PASS, n_res, nrow(ch)))
    saveRDS(list(ids = ch$id, result = r), cache_file(k))
    n_ok <- n_ok + 1L; n_timeout <- 0L   # a success clears the timeout streak
    ok_streak <- ok_streak + 1L
    if (ok_streak >= SPEEDUP_AFTER) {
      interval <- max(INTERVAL_MIN, interval * SPEEDUP_MULT)
      ok_streak <- 0L
    }
  } else n_err <- n_err + 1L
  unlink(claim_file(k))

  ## Deliberately NO re-probe here.
  ##
  ## The probe reserves ~4,500 tokens and the request ~4,455; both inside one
  ## minute is ~8,955 against an 8,000-per-minute bucket. Re-probing after every
  ## failure therefore created a feedback loop: a failure triggered a probe, the
  ## probe plus the retry breached the per-minute limit, that failed too, which
  ## triggered another probe. Keys with plenty of DAILY budget sat in permanent
  ## backoff because of it.
  ##
  ## The pre-request probe is not needed to detect exhaustion anyway: a real
  ## request's own error message distinguishes per-day from per-minute, and
  ## setTimeLimit bounds how long a request can stall. So the budget is checked
  ## once at startup and once after a timeout, and never in the hot path.

  if (n_ok > 0 && n_ok %% 10 == 0) {
    done <- sum(vapply(batches, function(b) file.exists(cache_file(key_of(b))), logical(1)))
    el <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
    cat(sprintf("[S4-%s] %d/%d cached | worker %d ok %d failed | %.1f min | %.2f req/min
",
                PASS, done, length(batches), n_ok, n_err, el, n_ok / max(el, .01)))
    flush.console()
  }
  if (n_ok == 0 && n_attempt >= 10)
    stop("no request has succeeded after ", n_attempt, " attempts -- aborting")
  if (n_ok >= MAX_REQ) { cat(sprintf("[S4-%s] quota guard reached
", PASS)); break }
  ## Pace start-to-start, not by a fixed sleep. A request RESERVES ~4,455 tokens
  ## against this key's own 8,000-per-minute bucket, so the ceiling is
  ## 8000/4455 = 1.80 requests per minute PER KEY -- and each key has its own
  ## bucket and its own remaining daily budget. Sleeping a fixed 58s ran every
  ## key at ~55% of what it could do. Sleeping only the remainder of the target
  ## interval means a key that answered quickly starts its next request sooner,
  ## and each key independently runs as fast as it is individually allowed.
  el_req <- as.numeric(difftime(Sys.time(), t_req, units = "secs"))
  Sys.sleep(max(0, interval - el_req))
  if (n_ok > 0 && n_ok %% 10 == 0)
    cat(sprintf("[S4-%s] key %d pacing at %.0fs (%.2f req/min)
",
                PASS, KEY_IDX, interval, 60 / interval))
}
cat(sprintf("[S4-%s] worker finished: %d ok, %d failed, %.1f min%s
", PASS, n_ok, n_err,
            as.numeric(difftime(Sys.time(), t0, units = "mins")),
            if (quota_hit) " (daily budget reached)" else ""))

## ---- assemble -------------------------------------------------------------
rows <- list()
## Read EVERY cached batch in the directory, not just those whose key matches the
## current batching. A repair run groups the missing ids into fresh batches, so
## those files carry different cache keys -- iterating over `batches` skipped all
## of them and reported 4,197 annotations while the cache held 4,995. Each file
## stores its own id list alongside its result, so it is self-describing.
for (f in list.files(cache_dir, pattern = "[.]rds$", full.names = TRUE)) {
  cached <- tryCatch(readRDS(f), error = function(e) NULL)
  if (is.null(cached)) next
  r <- cached$result
  if (!is.list(r) || is.null(r$results) || !length(r$results)) next
  df <- if (is.data.frame(r$results)) as.data.table(r$results) else
          rbindlist(lapply(r$results, as.data.table), fill = TRUE)
  if (!nrow(df)) next
  ## the model is told to copy ids; fall back to the batch's own list if not
  if (!"id" %in% names(df) || anyNA(df$id) || !all(df$id %in% cached$ids))
    df[, id := cached$ids[seq_len(.N)]]
  rows[[length(rows) + 1]] <- df
}
if (!length(rows)) { cat("[S4] nothing to assemble yet\n"); quit(save = "no") }

out <- rbindlist(rows, fill = TRUE)
out <- unique(out, by = "id")
out[, `:=`(model = MODEL, pass = PASS, prompt_version = PROMPT_VERSION)]
outf <- sprintf("data/derived/llm_labels_%s.parquet", PASS)
write_parquet(out, outf, compression = "zstd")
cat(sprintf("[S4-%s] %s annotations -> %s\n", PASS,
            format(nrow(out), big.mark = ","), outf))

if ("stance" %in% names(out)) {
  cat("\nrelevance:\n"); print(out[, .N, by = relevance][order(-N)])
  cat("\nstance:\n");    print(out[, .N, by = stance][order(-N)])
}
inc_present <- intersect(inciv_fields, names(out))
if (length(inc_present))
  cat(sprintf("\nany incivility: %.1f%%\n",
              100 * mean(rowSums(as.matrix(out[, ..inc_present])) > 0, na.rm = TRUE)))
