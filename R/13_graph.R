## ---------------------------------------------------------------------------
## S13 -- KNOWLEDGE GRAPH OF THE DISCOURSE
##
## Open-ended triple extraction produces thousands of near-duplicate relations
## and an unreadable hairball, so the schema is closed: a fixed set of entity
## types and a fixed set of relations, enforced by the response schema exactly
## as the codebook is in S4. Entities are then canonicalised against an alias
## table, because an un-resolved graph in which "gpt", "ChatGPT" and "4o" are
## three different nodes measures nothing.
##
## Each edge carries the trust valence of the comment it came from, making this
## a SIGNED graph: it answers RQ1 rather than merely illustrating it.
##
## A random 100 triples are written out for hand-checking. A knowledge graph
## without an extraction-precision figure is decoration.
##
## Usage:  Rscript R/13_graph.R [max_requests] [key_index]
## Out:    data/derived/kg_edges.csv, kg_nodes.csv
##         output/tables/kg_centrality.csv, kg_communities.csv
##         output/tables/kg_precision_sample.csv   <- fill this in by hand
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(ellmer); library(arrow); library(data.table); library(openssl); library(igraph)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
set.seed(20260901)

args    <- commandArgs(trailingOnly = TRUE)
MAX_REQ <- as.integer(if (length(args) >= 1) args[1] else 300L)
KEY_IDX <- as.integer(if (length(args) >= 2) args[2] else 1L)
N_DOCS  <- as.integer(if (length(args) >= 3) args[3] else 1200L)
BATCH   <- 4L                    # extraction is heavier than classification
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
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
lab  <- if (file.exists("data/derived/llm_labels_A.parquet"))
          as.data.table(read_parquet("data/derived/llm_labels_A.parquet")) else NULL
if (!is.null(lab)) {
  ## annotations come back as factors; force character before any comparison
  d <- merge(samp[, .(id, text, subreddit)],
             lab[, .(id, relevance = as.character(relevance),
                     stance = as.character(stance))], by = "id")
  d <- d[relevance == "relevant"]
} else {
  d <- samp[has_ai_ref == TRUE, .(id, text, subreddit, stance = NA_character_)]
}
d <- d[nchar(text) >= 80]
if (nrow(d) > N_DOCS) {
  ## stratify on stance so the signed graph is not dominated by one valence
  d[, g := fifelse(is.na(stance), "unk", stance)]
  d <- d[, .SD[sample(.N, min(.N, ceiling(N_DOCS / uniqueN(d$g))))], by = g]
}
cat(sprintf("[S13] extracting from %s comments\n", format(nrow(d), big.mark = ",")))

## ---- schema -----------------------------------------------------------------
triple <- type_object(
  .description = "One relation asserted or implied by the comment",
  .additional_properties = FALSE,
  comment_id  = type_string("The id of the comment this came from."),
  subject     = type_string("Entity name as written, e.g. 'ChatGPT', 'OpenAI'."),
  subject_type= type_enum(ENT_TYPES),
  relation    = type_enum(REL_TYPES),
  object      = type_string("The other entity, or the harm/capability named."),
  object_type = type_enum(ENT_TYPES),
  valence     = type_enum(c("trusting", "distrusting", "neutral"),
                          "The stance the comment takes on this relation."))
schema <- type_object(.additional_properties = FALSE,
                      triples = type_array(triple, "Empty if the comment asserts none."))

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
Prefer few precise triples over many loose ones.")

make_user <- function(ch) paste0(
  "Extract triples from each comment. Copy comment_id exactly.\n\n",
  paste(sprintf("### id: %s\nCOMMENT: %s", ch$id, substr(ch$text, 1, 1500)), collapse = "\n\n"))

## ---- extract ----------------------------------------------------------------
d[, batch := ceiling(seq_len(.N) / BATCH)]
batches <- split(d, d$batch)
key_of <- function(ch) as.character(md5(paste("kg", MODEL, paste(ch$id, collapse = ","))))
cf <- function(k) file.path(cache_dir, paste0(k, ".rds"))
pending <- Filter(function(ch) !file.exists(cf(key_of(ch))), batches)
cat(sprintf("[S13] %d batches, %d cached, %d pending\n",
            length(batches), length(batches) - length(pending), length(pending)))
if (length(pending) > MAX_REQ) pending <- pending[seq_len(MAX_REQ)]

if (length(pending)) {
  ## A fresh Chat per request: ellmer's Chat object accumulates turn history, so
  ## reusing one grows the context until requests are rejected.
  new_chat <- function() chat_openai_compatible(
    base_url = "https://api.groq.com/openai/v1", system_prompt = sys, model = MODEL,
    credentials = function() list(Authorization = paste("Bearer", api_key)),
    api_args = list(reasoning_effort = "medium", temperature = 0), echo = "none")

  ## Sequential and paced, for the same reason as the annotation passes: Groq's
  ## per-minute token bucket is 8,000 per key and shared across models, so firing
  ## several extraction requests at once earns multi-minute backoffs that cost far
  ## more than the concurrency saves. Each response is cached the moment it lands.
  n_ok <- 0L; t0 <- Sys.time()
  for (j in seq_along(pending)) {
    b <- pending[[j]]
    r <- tryCatch(new_chat()$chat_structured(make_user(b), type = schema),
                  error = function(e) e)
    if (inherits(r, "condition")) {
      if (grepl("tokens per day|TPD", conditionMessage(r), ignore.case = TRUE)) {
        cat("[S13] daily token budget exhausted -- stopping cleanly\n"); break
      }
    } else if (is.list(r) && !is.null(r$triples)) {
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
  if (!length(r$triples)) next
  rows[[length(rows)+1]] <- rbindlist(lapply(r$triples, as.data.table), fill = TRUE)
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
E[, w := 1]
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
cat("      mark correct_yes_no by hand -> that number is the extraction precision\n")
