## ---------------------------------------------------------------------------
## S12c -- RQ3, TOPIC PART
##
## The regression answers the trust-category part of RQ3. The topic part is
## answered here, by cross-tabulation on the comments the topic model labelled,
## with a chi-square test and Cramer's V as the effect size.
## ---------------------------------------------------------------------------
suppressPackageStartupMessages(library(data.table))
setwd("/home/nishanksatish/Documents/Final_R/R")

D <- fread("output/tables/rq3_crosstab_input.csv")   # one row per labelled comment

cramers_v <- function(tab) {
  test <- suppressWarnings(chisq.test(tab, correct = FALSE))
  n    <- sum(tab)
  v    <- sqrt(unname(test$statistic) / (n * (min(dim(tab)) - 1)))
  ok   <- mean(test$expected < 5) <= 0.20 && min(test$expected) >= 1
  data.table(chi2 = round(unname(test$statistic), 1),
             df = unname(test$parameter), p = test$p.value,
             cramers_v = round(v, 3), cochran_ok = ok, n = n)
}

out <- rbindlist(list(
  cbind(test = "topic x incivility",  cramers_v(table(D$topic,   D$incivil))),
  cbind(test = "stance x incivility", cramers_v(table(D$stance3, D$incivil))),
  cbind(test = "topic x stance",      cramers_v(table(D$topic,   D$stance3)))))
print(out)
