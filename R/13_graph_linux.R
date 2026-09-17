## ---------------------------------------------------------------------------
## S13 (Linux runner) -- KNOWLEDGE GRAPH OF THE DISCOURSE
##
## Same design as 13_graph.R: closed entity/relation schema, entity
## canonicalisation, signed (trust/distrust) edges, centrality + community
## analysis, hand-check sample. Ported off `ellmer`/`arrow` (not installed on
## this machine, and adding them for a one-off run is unwarranted) onto
## httr2 + jsonlite + data.table, which are already installed here and were
## already proven working by this project's own R/09_llm_annotate-style calls.
## Structured output is enforced with Groq's json_schema response_format
## instead of ellmer's type_object/chat_structured.
##
## Usage:  Rscript R/13_graph_linux.R [max_requests] [key_index] [N_DOCS]
## Out:    data/derived/kg_edges.csv, kg_nodes.csv
##         output/tables/kg_centrality.csv, kg_communities.csv
##         output/tables/kg_precision_sample.csv   <- fill this in by hand
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table); library(httr2); library(jsonlite); library(openssl); library(igraph)
})
ROOT <- "/home/nishanksatish/Documents/Final_R/R"
setwd(ROOT)
set.seed(20260901)

args    <- commandArgs(trailingOnly = TRUE)
MAX_REQ <- as.integer(if (length(args) >= 1) args[1] else 100L)
KEY_IDX <- as.integer(if (length(args) >= 2) args[2] else 1L)
N_DOCS  <- as.integer(if (length(args) >= 3) args[3] else 1200L)
SHARD_COUNT <- as.integer(if (length(args) >= 4) args[4] else 1L)
SHARD_IDX   <- as.integer(if (length(args) >= 5) args[5] else 1L)
BATCH   <- 4L
MODEL   <- "openai/gpt-oss-120b"

KEYS <- trimws(readLines(if (file.exists("groq_keys.txt")) "groq_keys.txt" else "groq api.txt",
                         warn = FALSE))
KEYS <- KEYS[nzchar(KEYS) & !startsWith(KEYS, "#")]
api_key <- KEYS[((KEY_IDX - 1) %% length(KEYS)) + 1]
cache_dir <- "data/cache/kg"; dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

ENT_TYPES <- c("model", "company", "capability", "harm", "actor", "policy")
REL_TYPES <- c("accuses_of", "outperforms", "trusted_for", "distrusted_for",
               "threatens", "regulates", "replaces", "fabricates_about",
               "competes_with", "depends_on")

## ---- documents --------------------------------------------------------------
samp <- fread("data/derived/annotation_sample.csv", na.strings = c("", "NA"))
lab  <- if (file.exists("data/derived/llm_labels_A.csv"))
          fread("data/derived/llm_labels_A.csv", na.strings = c("", "NA")) else NULL
if (!is.null(lab)) {
  d <- merge(samp[, .(id, text, subreddit)],
             lab[, .(id, relevance = as.character(relevance), stance = as.character(stance))],
             by = "id")
  d <- d[relevance == "relevant"]
} else {
  d <- samp[has_ai_ref == TRUE, .(id, text, subreddit, stance = NA_character_)]
}
d <- d[nchar(text) >= 80]
if (nrow(d) > N_DOCS) {
  d[, g := fifelse(is.na(stance), "unk", stance)]
  d <- d[, .SD[sample(.N, min(.N, ceiling(N_DOCS / uniqueN(d$g))))], by = g]
}
cat(sprintf("[S13] extracting from %s comments\n", format(nrow(d), big.mark = ",")))

## ---- schema (JSON Schema, enforced server-side via response_format) --------
triple_schema <- list(
  type = "object", additionalProperties = FALSE,
  properties = list(
    triples = list(
      type = "array",
      items = list(
        type = "object", additionalProperties = FALSE,
        properties = list(
          comment_id   = list(type = "string"),
          subject      = list(type = "string"),
          subject_type = list(type = "string", enum = ENT_TYPES),
          relation     = list(type = "string", enum = REL_TYPES),
          object       = list(type = "string"),
          object_type  = list(type = "string", enum = ENT_TYPES),
          valence      = list(type = "string", enum = c("trusting", "distrusting", "neutral"))
        ),
        required = c("comment_id", "subject", "subject_type", "relation",
                     "object", "object_type", "valence")
      )
    )
  ),
  required = list("triples")
)

sys <- paste0(
"You extract a knowledge graph of how people talk about generative AI, from Reddit comments.

Return only relations the comment actually asserts or clearly implies. If a comment merely
reacts to something without asserting a relation between entities, return no triples for it.
Do not invent world knowledge that is not in the comment.

ENTITY TYPES: ", paste(ENT_TYPES, collapse = ", "), "
  model      a named system or product (ChatGPT, GPT-5, Claude, Gemini, DeepSeek, Midjourney)
  company    an organisation (OpenAI, Anthropic, Google, Meta)
  capability something a system can or cannot do (coding, image generation, reasoning)
  harm       a named harm or risk (job loss, misinformation, privacy loss, dependence)
  actor      a person or group (Sam Altman, artists, students, regulators, users)
  policy     a rule, law, guardrail or terms-of-service provision

RELATION TYPES: ", paste(REL_TYPES, collapse = ", "), "

Set valence to how the COMMENT frames the relation, not whether the relation is good.
Prefer few precise triples over many loose ones. Respond with JSON matching the given schema only.")

make_user <- function(ch) paste0(
  "Extract triples from each comment. Copy comment_id exactly.\n\n",
  paste(sprintf("### id: %s\nCOMMENT: %s", ch$id, substr(ch$text, 1, 1500)), collapse = "\n\n"))

## ---- Groq call with retry/backoff (pattern proven in R/09_llm_validation.R / R/10_knowledge_graph.R) ----
call_groq_structured <- function(user_msg, api_key, max_tries = 4) {
  req <- request("https://api.groq.com/openai/v1/chat/completions") |>
    req_auth_bearer_token(api_key) |>
    req_headers(`Content-Type` = "application/json") |>
    req_body_json(list(
      model = MODEL,
      messages = list(list(role = "system", content = sys),
                       list(role = "user", content = user_msg)),
      temperature = 0,
      reasoning_effort = "medium",
      max_tokens = 3000,
      response_format = list(type = "json_schema",
                              json_schema = list(name = "kg_triples", strict = TRUE, schema = triple_schema))
    )) |>
    req_error(is_error = function(resp) FALSE)

  for (attempt in seq_len(max_tries)) {
    resp <- tryCatch(req_perform(req), error = function(e) e)
    if (inherits(resp, "error") || inherits(resp, "condition")) {
      Sys.sleep(min(2 * 2^(attempt - 1), 30)); next
    }
    status <- resp_status(resp)
    if (status == 429) {
      wait <- suppressWarnings(as.numeric(tryCatch(resp_header(resp, "Retry-After"), error = function(e) NA)))
      if (is.na(wait)) wait <- min(2 * 2^(attempt - 1), 30)
      Sys.sleep(wait); next
    }
    if (status >= 500) { Sys.sleep(min(2 * 2^(attempt - 1), 30)); next }
    if (status >= 400) return(NULL)
    body <- tryCatch(resp_body_json(resp), error = function(e) NULL)
    content <- tryCatch(body$choices[[1]]$message$content, error = function(e) NULL)
    if (is.null(content) || !nzchar(content)) return(NULL)
    parsed <- tryCatch(fromJSON(content, simplifyVector = TRUE), error = function(e) NULL)
    return(parsed)
  }
  NULL
}

## ---- extract ----------------------------------------------------------------
d[, batch := ceiling(seq_len(.N) / BATCH)]
batches <- split(d, d$batch)
key_of <- function(ch) as.character(md5(paste("kg", MODEL, paste(ch$id, collapse = ","))))
cf <- function(k) file.path(cache_dir, paste0(k, ".rds"))
pending <- Filter(function(ch) !file.exists(cf(key_of(ch))), batches)
cat(sprintf("[S13] %d batches, %d cached, %d pending\n",
            length(batches), length(batches) - length(pending), length(pending)))
# Deterministic disjoint partition across concurrent shards (one per API key),
# so N parallel processes cover the pending set once each, not N times.
if (SHARD_COUNT > 1) {
  keep <- (seq_along(pending) %% SHARD_COUNT) == (SHARD_IDX %% SHARD_COUNT)
  pending <- pending[keep]
  cat(sprintf("[S13] shard %d/%d: %d batches assigned\n", SHARD_IDX, SHARD_COUNT, length(pending)))
}
if (length(pending) > MAX_REQ) pending <- pending[seq_len(MAX_REQ)]

if (length(pending)) {
  n_ok <- 0L; t0 <- Sys.time()
  for (j in seq_along(pending)) {
    b <- pending[[j]]
    r <- call_groq_structured(make_user(b), api_key)
    if (!is.null(r) && !is.null(r$triples)) {
      saveRDS(r, cf(key_of(b))); n_ok <- n_ok + 1L
      if (n_ok %% 10 == 0)
        cat(sprintf("[S13] %d/%d extracted | %.1f min\n", n_ok, length(pending),
                    as.numeric(difftime(Sys.time(), t0, units = "mins"))))
      flush.console()
    }
    Sys.sleep(28)
  }
}

## ---- assemble ---------------------------------------------------------------
rows <- list()
for (ch in batches) {
  f <- cf(key_of(ch)); if (!file.exists(f)) next
  r <- readRDS(f)
  tr <- r$triples
  if (is.null(tr) || (is.data.frame(tr) && nrow(tr) == 0) || (is.list(tr) && !is.data.frame(tr) && length(tr) == 0)) next
  if (!is.data.frame(tr)) tr <- rbindlist(lapply(tr, as.data.table), fill = TRUE)
  rows[[length(rows) + 1]] <- as.data.table(tr)
}
if (!length(rows)) { cat("[S13] no triples extracted yet\n"); quit(save = "no") }
E <- rbindlist(rows, fill = TRUE)
cat(sprintf("[S13] %s raw triples\n", format(nrow(E), big.mark = ",")))

## ---- entity canonicalisation ------------------------------------------------
canon <- function(x) {
  v <- tolower(trimws(gsub("[[:punct:]]+$", "", x)))
  v <- gsub("\\s+", " ", v)
  rules <- list(
    "ChatGPT"   = "^(chat ?gpt|gpt[- ]?[0-9.]*[a-z]*|4o|o[0-9]|openai's model.*)$",
    "OpenAI"    = "^(open ?ai|openai inc.*)$",
    "Claude"    = "^(claude.*)$",
    "Anthropic" = "^(anthropic.*)$",
    "Gemini"    = "^(gemini.*|bard)$",
    "Google"    = "^(google|alphabet|deepmind|google deepmind)$",
    "DeepSeek"  = "^(deep ?seek.*)$",
    "Llama"     = "^(llama.*|meta ai)$",
    "Meta"      = "^(meta|facebook)$",
    "Grok"      = "^(grok.*)$",
    "Sam Altman"= "^(sam altman|altman)$",
    "Elon Musk" = "^(elon musk|musk|elon)$",
    "Midjourney"= "^(midjourney.*)$",
    "AI (general)" = "^(ai|a\\.i\\.|artificial intelligence|generative ai|gen ?ai|llms?|large language models?|ai models?)$")
  out <- x
  for (nm in names(rules)) out[grepl(rules[[nm]], v)] <- nm
  out[!(out %in% names(rules))] <- tools::toTitleCase(v[!(out %in% names(rules))])
  out
}
E[, `:=`(subject = canon(subject), object = canon(object))]
E <- E[nzchar(subject) & nzchar(object) & subject != object]
EA <- E[, .(weight = .N,
            trusting    = sum(valence == "trusting"),
            distrusting = sum(valence == "distrusting")),
        by = .(subject, subject_type, relation, object, object_type)]
EA[, sign := fifelse(distrusting > trusting, -1L, fifelse(trusting > distrusting, 1L, 0L))]
setorder(EA, -weight)
fwrite(EA, "data/derived/kg_edges.csv")
cat(sprintf("[S13] %s canonical edges over %s nodes\n",
            format(nrow(EA), big.mark = ","),
            format(uniqueN(c(EA$subject, EA$object)), big.mark = ",")))
cat("\n[S13] strongest edges\n"); print(head(EA[, .(subject, relation, object, weight, sign)], 20))

## ---- graph analysis ---------------------------------------------------------
g <- graph_from_data_frame(EA[, .(from = subject, to = object, weight, sign)], directed = TRUE)
V(g)$degree  <- degree(g)
V(g)$btw     <- betweenness(g, weights = NA)
ug <- as_undirected(g, mode = "collapse", edge.attr.comb = list(weight = "sum", "ignore"))
comm <- cluster_leiden(ug, objective_function = "modularity", weights = E(ug)$weight)
V(g)$community <- membership(comm)[V(g)$name]

nodes <- data.table(node = V(g)$name, degree = V(g)$degree,
                    betweenness = round(V(g)$btw, 1), community = V(g)$community)
tps <- unique(rbind(EA[, .(node = subject, type = subject_type)],
                    EA[, .(node = object,  type = object_type)]), by = "node")
nodes <- merge(nodes, tps, by = "node", all.x = TRUE)[order(-degree)]
fwrite(nodes, "data/derived/kg_nodes.csv")
fwrite(head(nodes, 40), "output/tables/kg_centrality.csv")
cat("\n[S13] most central entities\n"); print(head(nodes, 15))

cs <- nodes[, .(n = .N, members = paste(head(node[order(-degree)], 8), collapse = ", ")),
            by = community][order(-n)]
fwrite(cs, "output/tables/kg_communities.csv")
cat(sprintf("\n[S13] %d communities (modularity %.3f)\n", length(unique(nodes$community)),
            modularity(ug, membership(comm))))
print(head(cs, 8))

## ---- precision sample for hand-checking -------------------------------------
set.seed(99)
ps <- E[sample(.N, min(100, .N)), .(comment_id, subject, relation, object, valence)]
ps[, correct_yes_no := ""]
fwrite(ps, "output/tables/kg_precision_sample.csv")
cat("\n[S13] 100 triples written to output/tables/kg_precision_sample.csv\n")
