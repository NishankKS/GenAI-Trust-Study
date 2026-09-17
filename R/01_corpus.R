## ---------------------------------------------------------------------------
## S1 -- CORPUS CONSTRUCTION, CLEANING, AND THE LEXICAL RELEVANCE PREFILTER
##
## Input : data/parquet/comments_raw.parquet, data/derived/depth.parquet
## Output: data/parquet/analysis_corpus.parquet
##         output/tables/funnel.csv        (the PRISMA-style exclusion funnel)
##         output/tables/corpus_describe.csv
##
## Every exclusion is counted and reported. Nothing is dropped silently.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(stringi)
})

ROOT <- "D:/GERMANY/NOTES/R"
setwd(ROOT)
set.seed(20260901)

funnel <- data.table(step = character(), n = integer(), note = character())
log_step <- function(step, n, note = "") {
  funnel <<- rbind(funnel, data.table(step = step, n = as.integer(n), note = note))
  cat(sprintf("  %-46s %10s  %s\n", step, format(n, big.mark = ","), note))
}

cat("[S1] reading parquet\n")
d <- as.data.table(read_parquet("data/parquet/comments_raw.parquet"))
dep <- as.data.table(read_parquet("data/derived/depth.parquet"))
d[dep, on = "id", depth := i.depth]
log_step("raw comments ingested", nrow(d))

## -- 1. window -------------------------------------------------------------
## The dump ends one day into September; a partial day would distort every
## monthly series, so the window is closed at six full months.
d <- d[created_ts >= as.POSIXct("2026-03-01", tz = "UTC") &
       created_ts <  as.POSIXct("2026-09-01", tz = "UTC")]
log_step("window 2026-03-01 to 2026-08-31", nrow(d))

## -- 2. deleted / removed --------------------------------------------------
d[, body := stri_enc_toutf8(body, is_unknown_8bit = TRUE, validate = TRUE)]
d <- d[!is.na(body) & !(body %chin% c("[deleted]", "[removed]", "[unavailable]", ""))]
log_step("deleted / removed / empty dropped", nrow(d))

## -- 3. bots and moderators -------------------------------------------------
## AutoModerator plus the naming convention Reddit bots follow. The share is
## large and uneven across venues (7.8% in r/ChatGPT, 29.0% in r/MachineLearning),
## so leaving them in would bias any cross-venue comparison.
bot_rx <- "(?i)^(automoderator|.*[-_]?bot[0-9]*|b0t|.*_ai_bot)$"
d[, is_bot := stri_detect_regex(author, bot_rx) |
              author %chin% c("[deleted]", "AutoModerator", "RemindMeBot",
                              "sneakpeekbot", "WikiSummarizerBot", "totesmessenger")]
n_bot <- sum(d$is_bot)
d <- d[is_bot == FALSE][, is_bot := NULL]
log_step("bots / AutoModerator dropped", nrow(d), sprintf("-%s", format(n_bot, big.mark = ",")))

d <- d[stickied == FALSE | is.na(stickied)]
log_step("stickied mod posts dropped", nrow(d))

## -- 3b. official moderation ------------------------------------------------
## Moderator boilerplate is not public discourse: it is the platform speaking
## about the discourse. Reddit marks it two ways, and both are needed --
## `distinguished == "moderator"` catches mods posting officially, while
## dedicated removal accounts (ChatGPT-ModTeam and friends) are not caught by
## the bot naming convention above. Left in, these comments contaminate the
## incivility measure in particular, since removal notices quote the rule being
## enforced ("abusive/offensive language is not allowed").
d[, is_mod := (!is.na(distinguished) & distinguished == "moderator") |
              stri_detect_regex(author, "(?i)(modteam|mod[-_ ]?team|moderator)$")]
n_mod <- sum(d$is_mod)
d <- d[is_mod == FALSE][, is_mod := NULL]
log_step("official moderation dropped", nrow(d), sprintf("-%s", format(n_mod, big.mark = ",")))

## -- 4. text normalisation --------------------------------------------------
## Order matters. Quote-stripping happens before any incivility measurement:
## a user who quotes an insult in order to condemn it must not be coded as the
## author of that insult. This removes a systematic false-positive class.
cat("[S1] normalising text\n")
d[, n_links := stri_count_regex(body, "https?://")]

txt <- d$body
txt <- stri_replace_all_fixed(txt,
        c("&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&nbsp;", "&#x200B;"),
        c("&",     "<",    ">",    "\"",     "'",     " ",      " "),
        vectorize_all = FALSE)
txt <- stri_replace_all_regex(txt, "(?s)```.*?```", " ")          # fenced code
txt <- stri_replace_all_regex(txt, "(?m)^\\s{4,}\\S.*$", " ")     # indented code
txt <- stri_replace_all_regex(txt, "(?m)^\\s*&gt;.*$", " ")       # quote (escaped)
txt <- stri_replace_all_regex(txt, "(?m)^\\s*>.*$", " ")          # quote block
txt <- stri_replace_all_regex(txt, "\\[([^]]{1,200})\\]\\([^)]*\\)", "$1")  # md link -> anchor text
txt <- stri_replace_all_regex(txt, "https?://\\S+", " ")          # bare urls
txt <- stri_replace_all_regex(txt, "/?[ru]/[A-Za-z0-9_-]+", " ")  # /u/ and /r/ mentions
txt <- stri_replace_all_regex(txt, "[*_~`^]+", "")                # md emphasis
txt <- stri_replace_all_regex(txt, "(?m)^#{1,6}\\s*", "")         # md headers
txt <- stri_replace_all_regex(txt, "\\s+", " ")
txt <- stri_trim_both(txt)
d[, text := txt]; rm(txt)

d[, n_words := stri_count_regex(text, "\\S+")]
d <- d[n_words >= 4]
log_step("shorter than 4 words dropped", nrow(d))

## -- 5. language ------------------------------------------------------------
## A function-word ratio detector rather than a model dependency: fast enough
## for a million documents and transparent enough to report.
fw <- paste0("\\b(the|and|to|of|a|in|is|it|you|that|for|on|this|but|not|with|",
             "are|have|be|was|i|my|we|they|do|so|if|just|like|can|what|how|",
             "why|would|about|there|their|from|all|get|one|out|up|more|will)\\b")
d[, fw_hits := stri_count_regex(stri_trans_tolower(text), fw)]
d[, latin_ratio := stri_count_regex(text, "[A-Za-z]") / pmax(1, stri_length(text))]
d[, is_en := (fw_hits / pmax(1, n_words)) >= 0.08 & latin_ratio >= 0.45]
n_noten <- sum(!d$is_en)
d <- d[is_en == TRUE]
log_step("non-English dropped", nrow(d), sprintf("-%s", format(n_noten, big.mark = ",")))

## -- 6. lexical relevance prefilter ----------------------------------------
## Deliberately HIGH RECALL. Its only job is to remove comments that make no
## reference whatsoever to an AI system, its makers, or its outputs; the real
## relevance decision (does this comment *evaluate* AI?) is made by the LLM in
## S4 and distilled to the corpus in S5. Erring toward inclusion here keeps
## that later decision unbiased.
ai_rx <- paste0(
  "(?i)\\b(a\\.?i\\.?|artificial intelligence|agi|asi|llm|llms|gpt[0-9.-]*|",
  "chat ?gpt|openai|open ai|sam altman|altman|claude|anthropic|gemini|bard|",
  "deepseek|qwen|llama|mistral|grok|xai|copilot|perplexity|midjourney|",
  "dall[- ]?e|stable diffusion|sora|veo|nano ?banana|flux|",
  "chatbot|chat bot|language model|foundation model|neural net(work)?|",
  "machine learning|deep learning|transformer|diffusion model|",
  "prompt(s|ing|ed)?|token(s|izer)?|fine[- ]?tun(e|ed|ing)|rlhf|",
  "hallucinat(e|es|ed|ing|ion|ions)|alignment|safety team|",
  "training data|context window|inference|agentic|agents?|",
  "automat(e|ed|ion)|robot(s|ics)?|algorithm(s|ic)?)\\b")
d[, has_ai_ref := stri_detect_regex(text, ai_rx)]
cat(sprintf("  %-46s %10s  (%.1f%% of surviving comments)\n",
            "lexical AI reference present", format(sum(d$has_ai_ref), big.mark = ","),
            100 * mean(d$has_ai_ref)))
log_step("lexical relevance prefilter (kept)", sum(d$has_ai_ref),
         "high-recall; LLM relevance decides in S4")

## -- 7. features for later stages -------------------------------------------
d[, `:=`(
  caps_ratio  = stri_count_regex(text, "[A-Z]") / pmax(1, stri_count_regex(text, "[A-Za-z]")),
  n_question  = stri_count_fixed(text, "?"),
  n_exclaim   = stri_count_fixed(text, "!"),
  n_2ndperson = stri_count_regex(stri_trans_tolower(text), "\\b(you|your|yours|u|ur)\\b"),
  parent_cid  = fifelse(is_top_level, NA_character_, substr(parent_id, 4, 100))
)]

## parent text, for the incivility-cascade models in S9
pt <- d[, .(parent_cid = id, parent_text = text, parent_author = author)]
d[pt, on = "parent_cid", `:=`(parent_text = i.parent_text, parent_author = i.parent_author)]

## -- 8. write ---------------------------------------------------------------
keep <- c("id","link_id","parent_id","parent_cid","subreddit","author","author_fullname",
          "created_utc","created_ts","ym","thread_slug","score","controversiality",
          "is_submitter","is_top_level","depth","text","n_words","n_chars","n_links",
          "caps_ratio","n_question","n_exclaim","n_2ndperson","has_ai_ref",
          "parent_text","parent_author")
ac <- d[, ..keep]
write_parquet(ac, "data/parquet/analysis_corpus.parquet", compression = "zstd")
cat(sprintf("[S1] analysis corpus written: %s rows\n", format(nrow(ac), big.mark = ",")))

fwrite(funnel, "output/tables/funnel.csv")

desc <- ac[, .(comments = .N,
               threads  = uniqueN(link_id),
               authors  = uniqueN(author),
               ai_ref_share = round(mean(has_ai_ref), 3),
               median_words = as.numeric(median(n_words)),
               top_level_share = round(mean(is_top_level), 3),
               median_depth = as.numeric(median(depth, na.rm = TRUE))),
           by = subreddit][order(-comments)]
fwrite(desc, "output/tables/corpus_describe.csv")
print(desc)

bym <- ac[, .(n = .N, ai_ref = round(mean(has_ai_ref), 3)), by = .(subreddit, ym)][order(subreddit, ym)]
fwrite(bym, "output/tables/corpus_by_month.csv")

cat("\n[S1] funnel\n"); print(funnel)
