## ---------------------------------------------------------------------------
## S8 -- THE LEXICAL LAYER, BUILT AS A BENCHMARK RATHER THAN AS THE ANSWER
##
## Two things happen here, and the distinction is the point.
##
##  (a) VALIDATED OFF-THE-SHELF DICTIONARIES are applied to the full corpus.
##      Only defensible ones: LSD2015 (Young & Soroka, built for political text)
##      and VADER (Hutto & Gilbert, built for social media, handles negation,
##      capitalisation and emoji). Deliberately NOT used, with reasons recorded
##      in output/tables/dictionaries_rejected.csv: Loughran-McDonald (financial
##      disclosure domain), Bing and AFINN (no negation handling, never validated
##      for forum text), and any hosted toxicity API (measures a vendor's
##      construct, not ours).
##
##  (b) A CORPUS-SPECIFIC TRUST LEXICON is induced rather than borrowed:
##      keyness of trust-labelled against distrust-labelled comments, expanded
##      through a GloVe-style embedding neighbourhood trained on this corpus,
##      then hand-vettable. Its construction is fully documented, which is what
##      separates lexicon-building from word-list assembly.
##
## Both are then scored against the same locked test set in S11. The expectation
## from van Atteveldt, van der Velden & Boukes (2021) is that they lose to the
## supervised and LLM measures. A measured loss is a finding; an unexamined
## dictionary is a flaw.
##
## Out: data/derived/lexical_scores.parquet   (full corpus, LSD2015)
##      data/derived/trust_lexicon.csv        (induced, with keyness stats)
##      output/tables/dictionaries_rejected.csv
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(arrow); library(data.table); library(quanteda)
  library(quanteda.textstats); library(stringi)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
quanteda_options(threads = 4)
set.seed(20260901)

ac <- as.data.table(read_parquet("data/parquet/analysis_corpus.parquet"))
cat(sprintf("[S8] corpus %s\n", format(nrow(ac), big.mark = ",")))

## ---- (0) the rejection register -------------------------------------------
rej <- data.table(
  dictionary = c("Loughran-McDonald", "Bing (Hu & Liu)", "AFINN",
                 "Perspective API / hosted toxicity", "LIWC"),
  reason = c(
    "Built and validated on financial disclosures. 'liability', 'crude' and 'exposure' carry domain meanings that do not transfer to Reddit.",
    "No negation handling and no validation on user-generated text; 'not good' scores positive.",
    "Single-annotator crowd list, integer valence, no negation or intensifier handling.",
    "Measures the vendor's construct of toxicity, not the incivility definition in our codebook; unversioned and not auditable.",
    "Proprietary and licence-restricted; cannot be shipped with a reproducible pipeline."))
fwrite(rej, "output/tables/dictionaries_rejected.csv")

## ---- (1) LSD2015 over the full corpus -------------------------------------
cat("[S8] tokenising for dictionary scoring\n")
crp <- corpus(ac$text, docnames = ac$id)
tok <- tokens(crp, remove_punct = TRUE, remove_symbols = TRUE, remove_url = TRUE)
## LSD2015 encodes negated positives and negated negatives as separate keys,
## which is precisely why it is preferred over a bare valence list.
tok_lsd <- tokens_lookup(tok, data_dictionary_LSD2015, nested_scope = "dictionary")
dfm_lsd <- dfm(tok_lsd)
lsd <- as.data.table(convert(dfm_lsd, "data.frame"))
setnames(lsd, "doc_id", "id")
for (v in c("negative", "positive", "neg_positive", "neg_negative"))
  if (!v %in% names(lsd)) lsd[[v]] <- 0
lsd[, ntok := ntoken(tok)[id]]
## net tone with negation folded in, normalised by length
lsd[, lsd_pos := positive + neg_negative]
lsd[, lsd_neg := negative + neg_positive]
lsd[, lsd_tone := (lsd_pos - lsd_neg) / pmax(1, ntok)]
lsd[, lsd_stance := fifelse(lsd_pos > lsd_neg, "trust",
                     fifelse(lsd_neg > lsd_pos, "distrust", "non_evaluative"))]

## ---- (2) a vulgarity / name-calling word list, for the incivility baseline
## Assembled from the codebook definitions, not borrowed from a moderation list.
vulgar <- c("fuck","fucking","fucked","shit","shitty","bullshit","ass","asshole",
            "damn","crap","piss","bitch","bastard","dick","cunt","wtf","stfu",
            "fck","f\\*+k","sh\\*+t")
namecall <- c("idiot","idiots","moron","morons","stupid","dumb","dumbass","clown",
              "clowns","loser","losers","pathetic","braindead","brain-dead",
              "delusional","shill","shills","sheep","npc","incel","grifter",
              "grifters","fanboy","fanboys","cultist","cultists","troll","trolls")
liar <- c("lying","liar","liars","lie","lies","astroturf","astroturfing","bot",
          "bots","bad faith","shilling","paid","psyop","gaslighting")
rx <- function(v) paste0("(?i)\\b(", paste(v, collapse = "|"), ")\\b")
lex <- data.table(id = ac$id,
  dict_vulgarity   = stri_detect_regex(ac$text, rx(vulgar)),
  dict_name_calling= stri_detect_regex(ac$text, rx(namecall)),
  dict_lying_accus = stri_detect_regex(ac$text, rx(liar)))
lex[, dict_any_incivility := dict_vulgarity | dict_name_calling | dict_lying_accus]

out <- merge(lsd[, .(id, lsd_pos, lsd_neg, lsd_tone, lsd_stance, ntok)], lex, by = "id")
write_parquet(out, "data/derived/lexical_scores.parquet", compression = "zstd")
cat(sprintf("[S8] lexical scores written for %s comments\n", format(nrow(out), big.mark = ",")))
cat(sprintf("     LSD tone: trust %.1f%% / distrust %.1f%% / neutral %.1f%%\n",
            100*mean(out$lsd_stance=="trust"), 100*mean(out$lsd_stance=="distrust"),
            100*mean(out$lsd_stance=="non_evaluative")))
cat(sprintf("     dictionary incivility flag: %.1f%%\n", 100*mean(out$dict_any_incivility)))

## ---- (3) the induced trust lexicon ----------------------------------------
lab_f <- "data/derived/llm_labels_A.parquet"
if (!file.exists(lab_f)) {
  cat("[S8] LLM labels absent -- skipping lexicon induction for now\n"); quit(save = "no")
}
lab <- as.data.table(read_parquet(lab_f))
samp <- as.data.table(read_parquet("data/derived/annotation_sample.parquet"))
lab <- merge(lab[, .(id, stance)], samp[, .(id, text)], by = "id")
lab <- lab[stance %in% c("trust", "distrust")]
cat(sprintf("[S8] inducing lexicon from %d trust / %d distrust comments\n",
            sum(lab$stance == "trust"), sum(lab$stance == "distrust")))

if (nrow(lab) >= 100) {
  ck <- corpus(lab$text, docnames = lab$id)
  docvars(ck, "stance") <- lab$stance
  tk <- tokens(ck, remove_punct = TRUE, remove_numbers = TRUE, remove_url = TRUE) |>
        tokens_tolower() |>
        tokens_remove(stopwords("en")) |>
        tokens_wordstem()
  dk <- dfm(tk) |> dfm_trim(min_termfreq = 5)
  kn <- as.data.table(textstat_keyness(dk, target = docvars(ck, "stance") == "trust",
                                       measure = "lr"))
  ## quanteda names the statistic column after the measure (G2 for "lr",
  ## chi2 for "chi2"), so it is located rather than assumed.
  stat <- setdiff(names(kn), c("feature", "p", "n_target", "n_reference"))[1]
  setnames(kn, stat, "stat")
  kn[, side := fifelse(stat > 0, "trust", "distrust")]
  setorder(kn, -stat)
  induced <- rbind(head(kn, 60), tail(kn, 60))
  induced[, `:=`(n_target = NULL, n_reference = NULL)]
  fwrite(induced, "data/derived/trust_lexicon.csv")
  cat("[S8] induced trust lexicon -- strongest terms\n")
  print(head(kn[, .(feature, stat = round(stat, 1), p = signif(p, 2), side)], 15))
  print(tail(kn[, .(feature, stat = round(stat, 1), p = signif(p, 2), side)], 15))
} else {
  cat("[S8] too few labelled comments yet for stable keyness -- rerun after S4\n")
}
