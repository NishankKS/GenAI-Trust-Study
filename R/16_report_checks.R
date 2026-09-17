## ---------------------------------------------------------------------------
## S16 -- REPORT CHECKS
##
## Reproduces, from the shipped tables alone, every headline number quoted in
## the seminar report. Nothing here estimates anything; it re-reads and
## re-derives, so a mismatch between the report and the pipeline shows up here
## rather than in a reader's spot check.
## ---------------------------------------------------------------------------
suppressPackageStartupMessages(library(data.table))
setwd("/home/nishanksatish/Documents/Final_R/R")
T <- function(f) fread(file.path("output/tables", f))
n <- function(x) format(x, big.mark = ",")

f <- T("funnel.csv"); d <- T("corpus_describe.csv")
cat(sprintf("corpus   raw %s -> analysis %s -> prefilter %s | retained %.1f%%\n",
            n(f$n[1]), n(f$n[8]), n(f$n[9]), 100 * f$n[8] / f$n[1]))
cat(sprintf("venues   %s | threads %s | authors %s | AI-reference share %.3f\n",
            n(sum(d$comments)), n(sum(d$threads)), n(sum(d$authors)),
            weighted.mean(d$ai_ref_share, d$comments)))

sd <- T("sampling_design.csv")
cat(sprintf("sample   %d strata, n = %s, frame N = %s | r/MachineLearning %.1f%% of corpus, %.1f%% of sample\n",
            nrow(sd), n(sum(sd$n_h)), n(sum(sd$N_h)),
            100 * d[subreddit == "MachineLearning", comments] / sum(d$comments),
            100 * sd[grepl("^MachineLearning", stratum), sum(n_h)] / sum(sd$n_h)))

r <- T("reliability.csv")
cat(sprintf("coders   n = %d | alpha: %s\n", r$n[1],
            paste(sprintf("%s %.3f", r$variable[!is.na(r$alpha)], r$alpha[!is.na(r$alpha)]),
                  collapse = ", ")))
cat(sprintf("dropped  %s (zero instances by both coders, alpha undefined)\n",
            paste(r[is.na(alpha), variable], collapse = ", ")))

v <- T("validation.csv")
best <- v[, .SD[which.max(macro_f1)], by = construct]
cat("winners  ", paste(sprintf("%s: %s F1=%.3f", best$construct, best$instrument, best$macro_f1),
                       collapse = " | "), "\n", sep = "")
cat(sprintf("floor    stance dictionary LSD2015 F1=%.3f, distilled F1=%.3f\n",
            v[instrument %like% "LSD2015", macro_f1], v[construct == "stance" & instrument %like% "Distilled", macro_f1]))

im <- T("intermodel_agreement.csv")
cat(sprintf("inter-MODEL vs inter-CODER  relevance %.3f vs %.3f | stance %.3f vs %.3f | incivility %.3f vs %.3f\n",
            im[variable == "relevance", alpha],       r[variable == "relevance", alpha],
            im[variable == "stance", alpha],          r[variable == "stance", alpha],
            im[variable == "any_incivility", alpha],  r[variable == "any_incivility", alpha]))

p <- T("prevalence_corrected.csv")
cat("DSL      ", paste(sprintf("%s %.3f->%.3f [%.3f,%.3f]", p$quantity, p$naive, p$corrected,
                               p$ci_low, p$ci_high), collapse = " | "), "\n", sep = "")

ca <- T("calibration.csv"); cat(sprintf("ECE      %.3f over %d test comments\n", sum(ca$ece_contrib), sum(ca$n)))

tp <- T("topic_prevalence.csv"); ts <- T("topic_by_stance.csv")
cat(sprintf("topics   %d, labelled %s comments | most distrusting %s (%.3f), least %s (%.3f)\n",
            nrow(tp), n(sum(tp$n)), ts$topic[1], ts$distrust[1],
            ts$topic[nrow(ts)], ts$distrust[nrow(ts)]))

mi <- T("model_incivility.csv"); mc <- T("model_cascade.csv")
cat(sprintf("model    distrust OR = %.3f [%.3f, %.3f] | depth OR = %.3f | parent-uncivil OR = %.3f [%.3f, %.3f]\n",
            mi[term == "stance3distrust", odds_ratio], mi[term == "stance3distrust", or_low],
            mi[term == "stance3distrust", or_high], mi[term == "depth_c", odds_ratio],
            mc[term %like% "parent", odds_ratio], mc[term %like% "parent", or_low],
            mc[term %like% "parent", or_high]))

rq3 <- T("rq3_topic.csv"); tt <- T("rq3_topic_tests.csv")
cat(sprintf("RQ3      incivility by topic %.4f (%s) to %.4f (%s) | %s\n",
            max(rq3$incivil), rq3$topic[which.max(rq3$incivil)],
            min(rq3$incivil), rq3$topic[which.min(rq3$incivil)],
            paste(sprintf("%s V=%.3f", tt$test, tt$cramers_v), collapse = " | ")))

E <- fread("data/derived/kg_edges.csv"); N <- fread("data/derived/kg_nodes.csv")
ps <- T("kg_precision_sample.csv")
cat(sprintf("graph    %d edges / %d entities / %d communities | signs -1:%d 0:%d +1:%d | hand-checked %d of %d\n",
            nrow(E), nrow(N), uniqueN(N$community), sum(E$sign < 0), sum(E$sign == 0),
            sum(E$sign > 0), sum(!is.na(ps$correct_yes_no) & nzchar(as.character(ps$correct_yes_no))), nrow(ps)))
