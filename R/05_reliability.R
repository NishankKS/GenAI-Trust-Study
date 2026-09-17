## ---------------------------------------------------------------------------
## S5 -- INTERCODER RELIABILITY AND THE GOLD STANDARD
##
## Reads the two coders' CSV exports, reports Krippendorff's alpha per variable
## (never a single pooled number that hides a failing category), adjudicates
## disagreements, and writes the gold standard used by every later stage.
##
## If the human codes are not yet present the script falls back to a clearly
## labelled PROVISIONAL standard built from the LLM passes, so that the rest of
## the pipeline can be developed and run end to end. Every downstream table
## records which standard it used. Re-running this script after the human CSVs
## land silently upgrades the whole study.
##
## Input : coding/coded_UM.csv, coding/coded_NK.csv   (from the coding sheets)
## Output: data/derived/gold_labels.csv
##         output/tables/reliability.csv
##         output/tables/gold_provenance.txt
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table); library(arrow); library(irr)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")

INCIV <- cb_levels("incivility")
SINGLE <- c("relevance", "stance", "dimension", "target", "incivility_direction")

## ---------------------------------------------------------------------------
## Coders fill a spreadsheet, so the reader is deliberately forgiving: a closed
## field may be given as its number, its full label, or any unambiguous prefix,
## in any case, with stray whitespace. Anything it cannot resolve is returned as
## NA and counted in a parse report rather than silently guessed at.
norm_field <- function(x, field) {
  lv <- cb_levels(field)
  v  <- tolower(trimws(as.character(x)))
  v  <- gsub("[[:space:]]+", "_", gsub("[.,;]+$", "", v))
  out <- rep(NA_character_, length(v))
  num <- suppressWarnings(as.integer(v))
  ok  <- !is.na(num) & num >= 1 & num <= length(lv)
  out[ok] <- lv[num[ok]]
  exact <- match(v, lv)
  out[!is.na(exact)] <- lv[exact[!is.na(exact)]]
  todo <- which(is.na(out) & nzchar(v))
  for (i in todo) {                       # unambiguous prefix
    hit <- which(startsWith(lv, v[i]))
    if (length(hit) == 1) out[i] <- lv[hit]
  }
  out
}
norm_bool <- function(x) {
  v <- tolower(trimws(as.character(x)))
  v %in% c("x", "1", "y", "yes", "true", "t")
}

read_coder <- function(who) {
  ## accept whatever the coders named their return file
  cand <- sprintf(c("coding/coding_sheet_%s_annotated.csv",
                    "coding/coded_%s.csv",
                    "coding/coding_sheet_%s_coded.csv",
                    "coding/coding_sheet_%s.csv"), who)
  path <- cand[file.exists(cand)][1]
  if (is.na(path)) return(NULL)
  d <- fread(path, colClasses = "character", encoding = "UTF-8")
  for (v in SINGLE) d[[v]] <- norm_field(d[[v]], v)
  for (lv in INCIV) {
    col <- if (paste0("inc_", lv) %in% names(d)) paste0("inc_", lv) else lv
    d[[lv]] <- if (col %in% names(d)) norm_bool(d[[col]]) else FALSE
  }
  ## drop rows the coder has not reached yet
  coded <- !is.na(d$relevance)
  cat(sprintf("[S5] %s: %d of %d rows coded", basename(path), sum(coded), nrow(d)))
  unresolved <- sum(sapply(SINGLE, function(v) sum(is.na(d[[v]][coded]))))
  if (unresolved) cat(sprintf("  (%d unreadable cells -> NA)", unresolved))
  cat("\n")
  d[coded]
}

um <- read_coder("UM")
nk <- read_coder("NK")
have_human <- !is.null(um) && !is.null(nk) && nrow(um) > 30 && nrow(nk) > 30

samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
## Units found ineligible by the frame correction (R/02b_frame_correction.R) are
## dropped from the gold standard, exactly as a survey drops a sampled unit later
## found to be out of scope. The count is reported rather than absorbed.
if (!"eligible" %in% names(samp)) samp[, eligible := TRUE]
n_drop <- samp[in_gold == TRUE & eligible == FALSE, .N]
if (n_drop) cat(sprintf("[S5] %d coded comment(s) dropped as ineligible (official moderation)\n", n_drop))
gold_ids <- samp[in_gold == TRUE & eligible == TRUE, .(id, gold_split, subreddit)]
eligible_ids <- gold_ids$id

rel_tab <- data.table()
provenance <- character()

if (have_human) {
  cat(sprintf("[S5] human codes: UM %d, NK %d\n", nrow(um), nrow(nk)))
  both <- intersect(intersect(um$id, nk$id), eligible_ids)
  cat(sprintf("[S5] %d comments coded by both\n", length(both)))
  A <- um[id %in% both][order(id)]
  B <- nk[id %in% both][order(id)]

  ## ---- Krippendorff's alpha, per variable ---------------------------------
  kripp <- function(a, b, lvl = "nominal") {
    m <- rbind(as.character(a), as.character(b))
    if (length(unique(na.omit(as.vector(m)))) < 2) return(NA_real_)
    tryCatch(kripp.alpha(m, method = lvl)$value, error = function(e) NA_real_)
  }
  for (v in SINGLE)
    rel_tab <- rbind(rel_tab, data.table(
      variable = v, type = "nominal", n = length(both),
      alpha = kripp(A[[v]], B[[v]]),
      pct_agree = mean(A[[v]] == B[[v]], na.rm = TRUE),
      prevalence = NA_real_))
  for (v in INCIV)
    rel_tab <- rbind(rel_tab, data.table(
      variable = v, type = "binary", n = length(both),
      alpha = kripp(A[[v]], B[[v]]),
      pct_agree = mean(A[[v]] == B[[v]], na.rm = TRUE),
      prevalence = mean(c(A[[v]], B[[v]]))))
  anyA <- rowSums(as.matrix(A[, ..INCIV])) > 0
  anyB <- rowSums(as.matrix(B[, ..INCIV])) > 0
  rel_tab <- rbind(rel_tab, data.table(
    variable = "any_incivility", type = "binary", n = length(both),
    alpha = kripp(anyA, anyB), pct_agree = mean(anyA == anyB),
    prevalence = mean(c(anyA, anyB))))

  ## ---- adjudication --------------------------------------------------------
  ## Where the coders agree, that is the gold label. Where they disagree on a
  ## nominal variable the case is marked for adjudication; until it is
  ## adjudicated by hand the more conservative label is taken (the one implying
  ## less of the construct), which biases against finding our own effects.
  gold <- data.table(id = both)
  conservative <- list(relevance = "not_relevant", stance = "non_evaluative",
                       dimension = "not_applicable", target = "not_applicable",
                       incivility_direction = "none")
  for (v in SINGLE) {
    ag <- A[[v]] == B[[v]]
    gold[[v]] <- fifelse(ag, A[[v]], conservative[[v]])
    gold[[paste0(v, "_disputed")]] <- !ag
  }
  for (v in INCIV) gold[[v]] <- A[[v]] & B[[v]]   # both must see it
  gold[, any_incivility := rowSums(as.matrix(.SD)) > 0, .SDcols = INCIV]
  gold[, standard := "human"]
  provenance <- c(provenance,
    sprintf("HUMAN gold standard: %d comments double-coded by UM and NK.", length(both)),
    sprintf("Adjudication rule: agreement = label; disagreement = conservative label."),
    sprintf("Disputed rate by variable: %s",
            paste(sprintf("%s %.1f%%", SINGLE,
                          100 * sapply(SINGLE, function(v) mean(gold[[paste0(v,"_disputed")]]))),
                  collapse = ", ")))

} else {
  ## ---- provisional standard -----------------------------------------------
  cat("[S5] WARNING: human codes not found -- building a PROVISIONAL standard\n")
  cat("[S5] every result derived from it must be relabelled once the coders export.\n")
  la <- if (file.exists("data/derived/llm_labels_A.parquet"))
          as.data.table(read_parquet("data/derived/llm_labels_A.parquet")) else NULL
  if (is.null(la)) stop("no human codes and no LLM pass A -- nothing to build a standard from")
  gold <- la[id %in% eligible_ids]
  for (v in SINGLE) if (!v %in% names(gold)) gold[[v]] <- NA_character_
  for (v in INCIV)  if (!v %in% names(gold)) gold[[v]] <- FALSE
  gold[, any_incivility := rowSums(as.matrix(.SD)) > 0, .SDcols = INCIV]
  for (v in SINGLE) gold[[paste0(v, "_disputed")]] <- NA
  gold[, standard := "provisional_llm"]
  gold <- gold[, c("id", SINGLE, INCIV, "any_incivility",
                   paste0(SINGLE, "_disputed"), "standard"), with = FALSE]
  rel_tab <- data.table(variable = c(SINGLE, INCIV, "any_incivility"),
                        type = "n/a", n = nrow(gold), alpha = NA_real_,
                        pct_agree = NA_real_, prevalence = NA_real_)
  provenance <- c(provenance,
    "PROVISIONAL standard built from LLM pass A. NOT a validated gold standard.",
    "Re-run R/05_reliability.R once coding/coded_UM.csv and coded_NK.csv exist.")
}

gold[gold_ids, on = "id", `:=`(gold_split = i.gold_split, subreddit = i.subreddit)]
fwrite(gold, "data/derived/gold_labels.csv")
fwrite(rel_tab, "output/tables/reliability.csv")
writeLines(provenance, "output/tables/gold_provenance.txt")

cat("\n[S5] reliability\n")
print(rel_tab[, .(variable, n, alpha = round(alpha, 3),
                  pct_agree = round(pct_agree, 3), prevalence = round(prevalence, 3))])
cat(sprintf("\n[S5] gold standard: %d rows (%d dev / %d test), source = %s\n",
            nrow(gold), sum(gold$gold_split == "dev", na.rm = TRUE),
            sum(gold$gold_split == "test", na.rm = TRUE), gold$standard[1]))
if (have_human) {
  low <- rel_tab[!is.na(alpha) & alpha < 0.667, variable]
  if (length(low))
    cat(sprintf("\n[S5] BELOW ACCEPTABLE RELIABILITY (alpha < .667): %s\n",
                paste(low, collapse = ", ")),
        "    -> collapse or drop these categories and say so in the paper.\n")
}
