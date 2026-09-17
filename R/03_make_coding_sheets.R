## ---------------------------------------------------------------------------
## S3b -- CODING INSTRUMENT (CSV)
##
## One spreadsheet per coder, generated from the codebook and the gold sample.
## Separate files so the two codings stay independent, which is the
## precondition for a meaningful reliability coefficient.
##
## Design choices that exist purely to make 360 comments fast to code:
##   - the seven incivility categories are SEPARATE binary columns, so marking
##     one is a single character rather than typing a delimited list;
##   - every closed field accepts a NUMBER as well as the full label, so a
##     whole row can be coded from the number row without leaving the keyboard;
##   - the reader in R/05_reliability.R normalises numbers, labels, case,
##     whitespace and common abbreviations, so nothing has to be typed exactly.
##
## Out: coding/coding_sheet_UM.csv, coding/coding_sheet_NK.csv
##      coding/CODING_LEGEND.md
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({library(data.table)})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
source("R/codebook.R")

CODERS <- c(UM = "Utkarsh Midha", NK = "Nishank Kallollu Satish Kumar")
INCIV  <- cb_levels("incivility")
SINGLE <- c("relevance", "stance", "dimension", "target", "incivility_direction")
dir.create("coding", showWarnings = FALSE)

gold <- fread("data/derived/gold_sample.csv")
setorder(gold, id)                      # same order in both sheets

sheet <- data.table(
  row         = seq_len(nrow(gold)),
  id          = gold$id,
  subreddit   = gold$subreddit,
  thread      = substr(gold$thread_slug, 1, 70),
  ## parent_text is NA for top-level comments but reaches the CSV as an empty
  ## string, which reads as "context missing" rather than "there is none"
  replying_to = substr(fifelse(is.na(gold$parent_text) | !nzchar(gold$parent_text),
                               "(top-level comment -- no parent)",
                               gold$parent_text), 1, 400),
  comment     = gold$text
)
## empty columns for the coder to fill
for (v in SINGLE) sheet[[v]] <- ""
for (v in INCIV)  sheet[[paste0("inc_", v)]] <- ""
sheet[, notes := ""]

for (cd in names(CODERS)) {
  f <- sprintf("coding/coding_sheet_%s.csv", cd)
  fwrite(sheet, f, bom = TRUE)          # BOM so Excel opens UTF-8 correctly
  cat(sprintf("[S3b] %s  (%d rows, %d columns)\n", f, nrow(sheet), ncol(sheet)))
}

## ---- the legend ------------------------------------------------------------
num_legend <- function(field) {
  lv <- cb_levels(field)
  paste(sprintf("%d = %s", seq_along(lv), lv), collapse = "  ·  ")
}
md <- c(
"# Coding legend",
"",
"Fill one row per comment in `coding_sheet_<YOURINITIALS>.csv`. Save as CSV",
"(UTF-8) with the same filename when you are done.",
"",
"**You may type either the number or the full label.** Case, spaces and",
"trailing punctuation are all forgiven by the reader. Leave `notes` blank",
"unless something needs flagging for adjudication.",
"",
"Quoted text, code blocks and links were stripped before you see the comment,",
"so every word in the `comment` column is that commenter's own. Code what the",
"comment **says**, not what you think the person believes.",
"",
"---",
"")
for (v in SINGLE) {
  cb <- CODEBOOK[[v]]
  md <- c(md, sprintf("## `%s`", v), "", cb$question, "",
          sprintf("`%s`", num_legend(v)), "")
  for (lv in names(cb$levels))
    md <- c(md, sprintf("- **%s** — %s", lv, cb$levels[[lv]]$def))
  md <- c(md, "")
}
md <- c(md,
"## `inc_*` — the seven incivility columns", "",
"Mark **x** (or 1) if the comment contains it, leave blank if not. More than",
"one may apply. These are coded for **every** comment, relevant or not.", "")
for (lv in INCIV)
  md <- c(md, sprintf("- **inc_%s** — %s", lv, CODEBOOK$incivility$levels[[lv]]$def))
md <- c(md, "",
"---", "",
"## Decision rules that settle most hard cases", "",
"1. **Criticising an AI is distrust, not incivility.** \"GPT-5 hallucinates constantly\"",
"   is `distrust` with no incivility. \"GPT-5 is a useless piece of shit\" is `distrust`",
"   **and** `inc_vulgarity` with direction `at_ai`.",
"2. **Trust is not positive sentiment.** An excited comment about an image it made",
"   is `not_relevant` unless it says something about the system being good, reliable,",
"   or worth relying on.",
"3. **Ambivalent is a real category.** \"Great for boilerplate, never for anything legal\"",
"   is `ambivalent`, not trust and not distrust.",
"4. **If `relevance` = not_relevant**, set `stance` = non_evaluative and both",
"   `dimension` and `target` = not_applicable. Still code the `inc_*` columns.",
"5. **Sarcasm carries its intended meaning**, not its literal one.",
"6. When genuinely torn, pick the more conservative option (the one claiming less)",
"   and write a word in `notes`.")
writeLines(md, "coding/CODING_LEGEND.md")
cat("[S3b] coding/CODING_LEGEND.md written\n")

## a one-line-per-field quick reference, for keeping next to the spreadsheet
qr <- data.table(column = c(SINGLE, paste0("inc_", INCIV)),
                 allowed = c(sapply(SINGLE, num_legend),
                             rep("x or 1 = yes, blank = no", length(INCIV))))
fwrite(qr, "coding/CODING_LEGEND.csv", bom = TRUE)
cat("[S3b] coding/CODING_LEGEND.csv written\n")
print(qr)
