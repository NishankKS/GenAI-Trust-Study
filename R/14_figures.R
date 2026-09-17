## ---------------------------------------------------------------------------
## S14 -- FIGURES
##
## Every figure is guarded by the existence of its input, so this can be run at
## any point in the pipeline and will draw whatever is ready. Nothing here
## computes a result; it only renders results already written to output/tables.
##
## Out: output/figures/*.png  (300 dpi)
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table); library(ggplot2); library(arrow)
})
ROOT <- "D:/GERMANY/NOTES/R"; setwd(ROOT)
dir.create("output/figures", recursive = TRUE, showWarnings = FALSE)

## A single visual language for the whole paper: one accent for magnitude, a
## diverging pair for the trust/distrust axis, and nothing else.
INK <- "#14181F"; MUT <- "#616A7C"; RULE <- "#D6DAE3"
ACC <- "#33417C"; TRUST <- "#1B6B58"; DISTRUST <- "#9C3A2B"; INCIV <- "#96670C"
PAL <- c(trust = TRUST, distrust = DISTRUST, ambivalent = "#7A6BA8",
         non_evaluative = "#9AA3B2")

theme_paper <- function(base = 11) {
  theme_minimal(base_size = base) +
    theme(text = element_text(colour = INK),
          plot.title = element_text(face = "bold", size = base + 2, hjust = 0),
          plot.subtitle = element_text(colour = MUT, size = base - 0.5, hjust = 0,
                                       margin = margin(b = 10)),
          plot.caption = element_text(colour = MUT, size = base - 2, hjust = 0,
                                      margin = margin(t = 10)),
          panel.grid.minor = element_blank(),
          panel.grid.major = element_line(colour = RULE, linewidth = 0.3),
          axis.title = element_text(colour = MUT, size = base - 1),
          legend.position = "top", legend.title = element_blank(),
          strip.text = element_text(face = "bold", colour = INK))
}
save_fig <- function(p, name, w = 8, h = 5) {
  ggsave(file.path("output/figures", paste0(name, ".png")), p,
         width = w, height = h, dpi = 300, bg = "white")
  cat(sprintf("  [fig] %s\n", name))
}
have <- function(f) file.exists(f)

cat("[S14] rendering figures\n")

## ---- 1. exclusion funnel ----------------------------------------------------
if (have("output/tables/funnel.csv")) {
  f <- fread("output/tables/funnel.csv")
  f[, step := factor(step, levels = rev(step))]
  f[, lab := format(n, big.mark = ",")]
  p <- ggplot(f, aes(n, step)) +
    geom_col(fill = ACC, width = .68) +
    geom_text(aes(label = lab), hjust = -0.08, size = 3.1, colour = INK) +
    scale_x_continuous(expand = expansion(mult = c(0, .22)), labels = scales::comma) +
    labs(title = "From raw dump to analysis corpus",
         subtitle = "Every exclusion is counted; none is silent",
         x = "comments remaining", y = NULL,
         caption = "Reddit comments, r/ChatGPT + r/OpenAI + r/artificial + r/MachineLearning, 2026-03-01 to 2026-08-31") +
    theme_paper()
  save_fig(p, "01_funnel", 9, 4.6)
}

## ---- 2. corpus over time ----------------------------------------------------
if (have("output/tables/corpus_by_month.csv")) {
  m <- fread("output/tables/corpus_by_month.csv")
  p <- ggplot(m, aes(ym, n, fill = subreddit)) +
    geom_col(width = .7) +
    scale_fill_manual(values = c(ChatGPT = ACC, OpenAI = "#5C6FA8",
                                 artificial = "#8E9BC9", MachineLearning = "#C3C9DE")) +
    scale_y_continuous(labels = scales::comma, expand = expansion(mult = c(0, .05))) +
    labs(title = "Comment volume by month and venue",
         subtitle = "r/ChatGPT supplies roughly seven in ten comments, which is why every estimate is stratified",
         x = NULL, y = "comments") +
    theme_paper()
  save_fig(p, "02_volume_by_month", 8, 4.4)
}

## ---- 3. intercoder reliability ----------------------------------------------
if (have("output/tables/reliability.csv")) {
  r <- fread("output/tables/reliability.csv")[!is.na(alpha)]
  if (nrow(r)) {
    r[, variable := factor(variable, levels = r[order(alpha)]$variable)]
    p <- ggplot(r, aes(alpha, variable)) +
      geom_vline(xintercept = c(.667, .8), linetype = c("dotted", "dashed"),
                 colour = c(DISTRUST, MUT)) +
      geom_segment(aes(x = 0, xend = alpha, yend = variable), colour = RULE, linewidth = 1.4) +
      geom_point(size = 3.4, colour = ACC) +
      geom_text(aes(label = sprintf("%.3f", alpha)), hjust = -0.35, size = 3, colour = INK) +
      scale_x_continuous(limits = c(0, 1.08), breaks = seq(0, 1, .2),
                         expand = expansion(mult = c(0, 0))) +
      labs(title = "Intercoder reliability, per variable",
           subtitle = "Krippendorff's alpha, 360 comments double-coded. Dotted .667, dashed .80",
           x = expression(alpha), y = NULL,
           caption = "identity_attack and threat are omitted: both coders recorded zero instances, so alpha is undefined") +
      theme_paper()
    save_fig(p, "03_reliability", 8, 4.8)
  }
}

## ---- 4. the validation table -------------------------------------------------
if (have("output/tables/validation.csv")) {
  v <- fread("output/tables/validation.csv")
  v[, instrument := factor(instrument, levels = unique(v[order(macro_f1)]$instrument))]
  p <- ggplot(v, aes(macro_f1, instrument, fill = construct)) +
    geom_col(width = .68) +
    geom_text(aes(label = sprintf("%.2f", macro_f1)), hjust = -0.15, size = 2.9, colour = INK) +
    facet_wrap(~ construct, scales = "free_y", ncol = 1) +
    scale_fill_manual(values = c(relevance = ACC, stance = TRUST, any_incivility = INCIV)) +
    scale_x_continuous(limits = c(0, 1.1), expand = expansion(mult = c(0, 0))) +
    labs(title = "Every instrument, one gold standard, one locked test set",
         subtitle = "Macro-F1 against 150 human-coded comments never used for tuning",
         x = "macro-F1", y = NULL) +
    theme_paper() + theme(legend.position = "none")
  save_fig(p, "04_validation", 8.5, 7)
}

## ---- 5. naive vs error-corrected prevalence ---------------------------------
if (have("output/tables/prevalence_corrected.csv")) {
  pv <- fread("output/tables/prevalence_corrected.csv")
  pl <- melt(pv[, .(quantity, naive, corrected)], id.vars = "quantity",
             variable.name = "estimator", value.name = "est")
  p <- ggplot(pl, aes(est, quantity, colour = estimator)) +
    geom_errorbarh(data = pv, inherit.aes = FALSE,
                   aes(y = quantity, xmin = ci_low, xmax = ci_high),
                   height = .12, colour = MUT, linewidth = .5) +
    geom_point(size = 3.6) +
    scale_colour_manual(values = c(naive = MUT, corrected = ACC),
                        labels = c("naive (classifier output)", "DSL-corrected")) +
    scale_x_continuous(labels = scales::percent) +
    labs(title = "What the error correction changes",
         subtitle = "Classifier output vs the design-based corrected estimate, with 95% bootstrap intervals",
         x = "prevalence", y = NULL,
         caption = "Correction uses the human-coded probability subsample; intervals reflect classifier error, which the naive estimate ignores") +
    theme_paper()
  save_fig(p, "05_prevalence_corrected", 8.5, 4.2)
}

## ---- 6. topic prevalence ------------------------------------------------------
if (have("output/tables/topic_prevalence.csv")) {
  tp <- fread("output/tables/topic_prevalence.csv")
  tp[, topic := factor(topic, levels = tp[order(share)]$topic)]
  p <- ggplot(tp, aes(share, topic)) +
    geom_col(fill = ACC, width = .68) +
    geom_text(aes(label = scales::percent(share, .1)), hjust = -0.12, size = 3, colour = INK) +
    scale_x_continuous(labels = scales::percent, expand = expansion(mult = c(0, .18))) +
    labs(title = "What the discussion is about",
         subtitle = "Seeded LDA over comments the relevance gate kept",
         x = "share of relevant comments", y = NULL) +
    theme_paper()
  save_fig(p, "06_topic_prevalence", 8, 5)
}

## ---- 7. topic x stance --------------------------------------------------------
if (have("output/tables/topic_by_stance.csv")) {
  ts <- fread("output/tables/topic_by_stance.csv")
  keep <- intersect(c("trust", "distrust", "ambivalent", "non_evaluative"), names(ts))
  tl <- melt(ts[, c("topic", keep), with = FALSE], id.vars = "topic",
             variable.name = "stance", value.name = "share")
  tl[, topic := factor(topic, levels = ts[order(-distrust)]$topic)]
  p <- ggplot(tl, aes(stance, topic, fill = share)) +
    geom_tile(colour = "white", linewidth = .6) +
    geom_text(aes(label = scales::percent(share, 1)), size = 2.8,
              colour = ifelse(tl$share > .5, "white", INK)) +
    scale_fill_gradient(low = "#EFF1F7", high = ACC, labels = scales::percent) +
    labs(title = "Which themes carry distrust",
         subtitle = "Stance composition within each topic",
         x = NULL, y = NULL) +
    theme_paper() + theme(panel.grid = element_blank())
  save_fig(p, "07_topic_by_stance", 7.5, 5)
}

## ---- 8. incivility model coefficients ----------------------------------------
if (have("output/tables/model_incivility.csv")) {
  co <- fread("output/tables/model_incivility.csv")
  co <- co[!grepl("^month|Intercept", term)]
  co[, term := factor(term, levels = co[order(odds_ratio)]$term)]
  p <- ggplot(co, aes(odds_ratio, term)) +
    geom_vline(xintercept = 1, colour = MUT, linetype = "dashed") +
    geom_errorbarh(aes(xmin = or_low, xmax = or_high), height = .16, colour = MUT) +
    geom_point(size = 3, colour = ACC) +
    scale_x_log10() +
    labs(title = "What predicts incivility",
         subtitle = "Multilevel logistic regression, comments nested in threads. Odds ratios with 95% CI",
         x = "odds ratio (log scale)", y = NULL,
         caption = "p-values adjusted with Benjamini-Hochberg; month fixed effects fitted but not shown") +
    theme_paper()
  save_fig(p, "08_incivility_model", 8.5, 5.5)
}

## ---- 9. the cascade -----------------------------------------------------------
if (have("output/tables/model_cascade.csv")) {
  cc <- fread("output/tables/model_cascade.csv")[grepl("parent_incivil", term)]
  if (nrow(cc)) {
    p <- ggplot(cc, aes(odds_ratio, term)) +
      geom_vline(xintercept = 1, colour = MUT, linetype = "dashed") +
      geom_errorbarh(aes(xmin = or_low, xmax = or_high), height = .1, colour = MUT) +
      geom_point(size = 4, colour = INCIV) +
      labs(title = "Does incivility beget incivility?",
           subtitle = "Odds of an uncivil reply given an uncivil parent, estimated within threads",
           x = "odds ratio", y = NULL,
           caption = "Thread random effects difference out topic, venue and the provocation that started the conversation") +
      theme_paper()
    save_fig(p, "09_cascade", 7.5, 3)
  }
}

## ---- 10. calibration ----------------------------------------------------------
if (have("output/tables/calibration.csv")) {
  ca <- fread("output/tables/calibration.csv")[n > 0]
  p <- ggplot(ca, aes(mean_pred, observed)) +
    geom_abline(slope = 1, intercept = 0, colour = MUT, linetype = "dashed") +
    geom_line(colour = ACC, linewidth = .8) +
    geom_point(aes(size = n), colour = ACC) +
    scale_size_area(max_size = 7) +
    coord_equal(xlim = c(0, 1), ylim = c(0, 1)) +
    labs(title = "Are the classifier's probabilities honest?",
         subtitle = "Predicted vs observed incivility rate, human-coded test set",
         x = "predicted probability", y = "observed rate") +
    theme_paper() + theme(legend.position = "none")
  save_fig(p, "10_calibration", 5.5, 5.5)
}

## ---- 11. knowledge graph -------------------------------------------------------
if (have("data/derived/kg_edges.csv") && requireNamespace("igraph", quietly = TRUE)) {
  suppressPackageStartupMessages(library(igraph))
  E <- fread("data/derived/kg_edges.csv")
  E <- E[order(-weight)][1:min(120, .N)]
  g <- graph_from_data_frame(E[, .(from = subject, to = object, weight, sign)], directed = TRUE)
  set.seed(7); L <- layout_with_fr(g)
  png("output/figures/11_knowledge_graph.png", width = 2400, height = 1800, res = 300)
  par(mar = c(0, 0, 2.4, 0))
  ecol <- ifelse(E(g)$sign < 0, DISTRUST, ifelse(E(g)$sign > 0, TRUST, MUT))
  plot(g, layout = L,
       vertex.size = 3 + 5 * sqrt(degree(g)) / max(1, sqrt(max(degree(g)))) * 3,
       vertex.color = "#EFF1F7", vertex.frame.color = ACC,
       vertex.label.cex = .55, vertex.label.color = INK, vertex.label.family = "sans",
       edge.color = ecol, edge.width = 0.4 + 2 * E(g)$weight / max(E(g)$weight),
       edge.arrow.size = .25)
  title("Entities and relations in AI discourse", cex.main = 1, col.main = INK)
  mtext("green = trusting framing, red = distrusting; 120 strongest edges",
        side = 1, cex = .6, col = MUT, line = -1)
  dev.off()
  cat("  [fig] 11_knowledge_graph\n")
}

## ---- 12. removal bound ----------------------------------------------------------
if (have("output/tables/removal_bound.csv")) {
  rb <- fread("output/tables/removal_bound.csv")
  rl <- melt(rb[, .(subreddit, observed = observed_incivility, upper = worst_case_upper)],
             id.vars = "subreddit", variable.name = "bound", value.name = "v")
  p <- ggplot(rl, aes(v, reorder(subreddit, v), colour = bound)) +
    geom_line(aes(group = subreddit), colour = RULE, linewidth = 1.6) +
    geom_point(size = 3.4) +
    scale_colour_manual(values = c(observed = ACC, upper = DISTRUST),
                        labels = c("observed", "upper bound if every removed comment was uncivil")) +
    scale_x_continuous(labels = scales::percent) +
    labs(title = "Observed incivility is a floor, not an estimate",
         subtitle = "Moderator removal is not random with respect to incivility",
         x = "incivility rate", y = NULL) +
    theme_paper()
  save_fig(p, "12_removal_bound", 8.5, 3.6)
}

cat(sprintf("[S14] %d figures in output/figures\n",
            length(list.files("output/figures", pattern = "\\.png$"))))
