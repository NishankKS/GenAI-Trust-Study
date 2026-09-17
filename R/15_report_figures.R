## ---------------------------------------------------------------------------
## S15 -- FIGURES FOR THE SEMINAR REPORT
##
## Plain statistical graphics: theme_bw(), the shipped RColorBrewer palettes,
## serif type so figures match the body text, and no titles or subtitles inside
## the panel. Captions and interpretation live in the report, not in the image.
##
## Reads only output/tables/*.csv and data/derived/kg_*.csv, so it can be run at
## any time without re-running the analysis pipeline.
## Out: output/figures/report/*.png (300 dpi)
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table); library(ggplot2); library(scales); library(RColorBrewer)
})
ROOT <- "/home/nishanksatish/Documents/Final_R/R"; setwd(ROOT)
OUT <- "output/figures/report"
unlink(list.files(OUT, full.names = TRUE))
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

theme_set(theme_bw(base_size = 11, base_family = "serif"))
theme_update(panel.grid.minor = element_blank(), legend.position = "top",
             legend.title = element_blank(),
             strip.background = element_rect(fill = "grey92"))

T <- function(f) fread(file.path("output/tables", f))
fig <- function(p, name, w, h) {
  ggsave(file.path(OUT, paste0(name, ".png")), p, width = w, height = h,
         dpi = 300, bg = "white")
  cat(sprintf("  [fig] %s\n", name))
}
pretty_topic <- function(x)
  gsub("_", " ", sub("^other([0-9])$", "residual \\1", x))

## ---- 1  corpus volume by month and venue ------------------------------------
m <- T("corpus_by_month.csv")[ym < "2026-09"]
m[, subreddit := factor(subreddit, levels = c("ChatGPT", "OpenAI", "artificial",
                                              "MachineLearning"))]
fig(ggplot(m, aes(ym, n, fill = subreddit)) +
      geom_col(width = 0.7, colour = "grey30", linewidth = 0.2) +
      scale_fill_brewer(palette = "Blues", direction = -1) +
      scale_y_continuous(labels = comma, expand = expansion(mult = c(0, 0.05))) +
      labs(x = NULL, y = "comments"),
    "f01_volume", 7.0, 3.2)

## ---- 2  intercoder reliability ----------------------------------------------
r <- T("reliability.csv")[!is.na(alpha)]
r[, variable := factor(variable, levels = r[order(alpha)]$variable)]
fig(ggplot(r, aes(alpha, variable)) +
      geom_vline(xintercept = c(0.667, 0.800), linetype = c("dotted", "dashed"),
                 colour = "grey40") +
      geom_segment(aes(x = 0, xend = alpha, yend = variable), colour = "grey75") +
      geom_point(size = 2.6, colour = brewer.pal(9, "Blues")[8]) +
      geom_text(aes(label = sprintf("%.3f", alpha)), hjust = -0.3, size = 2.9,
                family = "serif") +
      scale_x_continuous(limits = c(0, 1.1), breaks = seq(0, 1, 0.2), expand = c(0, 0)) +
      labs(x = expression(paste("Krippendorff's ", alpha)), y = NULL),
    "f02_reliability", 7.0, 3.9)

## ---- 3  validation, coloured by measurement approach ------------------------
## The three constructs already separate the panels, so colour is free to carry
## the distinction that matters: which family of instrument produced the score.
v <- T("validation.csv")
v[, family := fifelse(grepl("^LLM", instrument), "LLM annotation",
              fifelse(grepl("Distilled", instrument), "Distilled classifier",
              fifelse(grepl("Dictionary", instrument), "Dictionary",
                      "Lexical rule / word list")))]
v[, family := factor(family, levels = c("LLM annotation", "Distilled classifier",
                                        "Lexical rule / word list", "Dictionary"))]
v[, construct := factor(construct, levels = c("relevance", "stance", "any_incivility"),
                        labels = c("relevance", "stance", "incivility"))]
v[, key := factor(paste(construct, instrument, sep = "|"),
                  levels = v[order(construct, macro_f1)][, paste(construct, instrument, sep = "|")])]
fig(ggplot(v, aes(macro_f1, key, fill = family)) +
      geom_col(width = 0.66, colour = "grey25", linewidth = 0.25) +
      geom_text(aes(label = sprintf("%.3f", macro_f1)), hjust = -0.18, size = 2.8,
                family = "serif") +
      facet_wrap(~ construct, scales = "free_y", ncol = 1) +
      scale_fill_brewer(palette = "Set2") +
      scale_y_discrete(labels = function(x) sub("^[^|]*[|]", "", x)) +
      scale_x_continuous(limits = c(0, 1.08), breaks = seq(0, 1, 0.2), expand = c(0, 0)) +
      labs(x = expression(paste("macro-", F[1], " against the human test set")), y = NULL),
    "f03_validation", 7.0, 5.6)

## ---- 4  dimension and target, share of evaluative comments ------------------
## The interpretable quantity is the split among comments where the field
## applies, so that is what the figure shows; the table carries naive,
## corrected and interval.
dt <- T("rq1_dimension_target_corrected.csv")[category != "not_applicable"]
dt[, category_type := factor(category_type, levels = c("dimension", "target"),
                             labels = c("trust dimension", "target of the stance"))]
dt[, key := factor(paste(category_type, category, sep = "|"),
                   levels = dt[order(category_type, corrected_share_of_evaluative)][
                     , paste(category_type, category, sep = "|")])]
fig(ggplot(dt, aes(corrected_share_of_evaluative, key)) +
      geom_col(fill = brewer.pal(9, "Blues")[6], width = 0.66,
               colour = "grey25", linewidth = 0.25) +
      geom_text(aes(label = percent(corrected_share_of_evaluative, 0.1)),
                hjust = -0.15, size = 2.9, family = "serif") +
      facet_wrap(~ category_type, scales = "free_y", ncol = 1) +
      scale_y_discrete(labels = function(x) gsub("_", " ", sub("^[^|]*[|]", "", x))) +
      scale_x_continuous(labels = percent, limits = c(0, 0.76), expand = c(0, 0)) +
      labs(x = "share of evaluative comments (error-corrected)", y = NULL),
    "f04_dimension_target", 7.0, 4.0)

## ---- 5  stance composition by topic -----------------------------------------
ts <- T("topic_by_stance.csv")
tl <- melt(ts[, .(topic, distrust, ambivalent, non_evaluative, trust)],
           id.vars = "topic", variable.name = "stance", value.name = "share")
tl[, topic := factor(pretty_topic(topic),
                     levels = pretty_topic(ts[order(distrust)]$topic))]
tl[, stance := factor(stance, levels = c("distrust", "ambivalent", "non_evaluative", "trust"),
                      labels = c("distrust", "ambivalent", "non-evaluative", "trust"))]
fig(ggplot(tl, aes(share, topic, fill = stance)) +
      geom_col(width = 0.72, colour = "grey25", linewidth = 0.25) +
      scale_fill_brewer(palette = "RdYlBu") +
      scale_x_continuous(labels = percent, expand = c(0, 0)) +
      labs(x = "share of comments in the topic", y = NULL),
    "f05_topic_stance", 7.0, 4.2)

## ---- 6  incivility by topic (RQ3, topic component) --------------------------
rq3 <- T("rq3_topic.csv")
rq3[, lab := pretty_topic(topic)]
rq3[, lab := factor(lab, levels = rq3[order(incivil)]$lab)]
rq3[, kind := fifelse(seeded, "seeded topic", "residual topic")]
fig(ggplot(rq3, aes(incivil, lab, fill = kind)) +
      geom_col(width = 0.68, colour = "grey25", linewidth = 0.25) +
      geom_text(aes(label = percent(incivil, 0.1)), hjust = -0.15, size = 2.9,
                family = "serif") +
      scale_fill_manual(values = c("seeded topic" = brewer.pal(9, "Blues")[6],
                                   "residual topic" = "grey70")) +
      scale_x_continuous(labels = percent, limits = c(0, 0.13), expand = c(0, 0)) +
      labs(x = "share of comments classified uncivil", y = NULL),
    "f06_topic_incivility", 7.0, 4.0)

## ---- 7  odds ratios from both logistic models -------------------------------
## One coefficient plot for both models, since both report odds ratios on the
## same outcome and the contrast between them is the point.
co <- T("model_incivility.csv")[!grepl("^month|Intercept", term) & is.finite(or_high)]
co[, model := "All comments, thread random intercept"]
cc <- T("model_cascade.csv")[term != "(Intercept)"]
cc[, model := "Replies only, within-thread"]
lab <- c("stance3distrust" = "distrust (vs non-evaluative)",
         "parent_incivilTRUE" = "parent comment uncivil",
         "depth_c" = "reply depth (per SD)",
         "n_2ndperson" = "second-person pronouns (per SD)",
         "caps_ratio" = "capitalisation (per SD)",
         "log_words" = "comment length (per SD)",
         "venueChatGPT" = "venue r/ChatGPT (vs r/artificial)",
         "venueOpenAI" = "venue r/OpenAI (vs r/artificial)",
         "venueMachineLearning" = "venue r/MachineLearning (vs r/artificial)")
A <- rbind(co[, .(term, odds_ratio, or_low, or_high, model)],
           cc[, .(term, odds_ratio, or_low, or_high, model)])
A[, lab := fifelse(term %in% names(lab), lab[term], term)]
A[, lab := factor(lab, levels = unique(A[order(model, odds_ratio)]$lab))]
A[, key := factor(paste(model, lab, sep = "|"),
                  levels = A[order(model, odds_ratio)][, paste(model, lab, sep = "|")])]
fig(ggplot(A, aes(odds_ratio, key)) +
      geom_vline(xintercept = 1, linetype = "dashed", colour = "grey40") +
      geom_errorbarh(aes(xmin = or_low, xmax = or_high), height = 0.18, colour = "grey35") +
      geom_point(size = 2.6, colour = brewer.pal(9, "Blues")[8]) +
      facet_grid(model ~ ., scales = "free_y", space = "free_y",
                 labeller = label_wrap_gen(22)) +
      scale_y_discrete(labels = function(x) sub("^[^|]*[|]", "", x)) +
      scale_x_log10(breaks = c(0.5, 0.75, 1, 1.5, 2, 3, 5)) +
      labs(x = "odds ratio (log scale), with 95% confidence interval", y = NULL) +
      theme(strip.text.y = element_text(angle = 0)),
    "f07_odds", 7.0, 4.2)

## ---- 8  removal bound --------------------------------------------------------
rb <- T("removal_bound.csv")
rl <- melt(rb[, .(subreddit, observed = observed_incivility, upper = worst_case_upper)],
           id.vars = "subreddit", variable.name = "bound", value.name = "v")
rl[, bound := factor(bound, levels = c("observed", "upper"),
                     labels = c("observed rate",
                                "upper bound if every removed comment were uncivil"))]
fig(ggplot(rl, aes(v, reorder(subreddit, v), shape = bound, colour = bound)) +
      geom_line(aes(group = subreddit), colour = "grey75", linewidth = 1) +
      geom_point(size = 2.8) +
      scale_colour_brewer(palette = "Set1") +
      scale_x_continuous(labels = percent, limits = c(0, 0.26)) +
      labs(x = "incivility rate", y = NULL) +
      theme(legend.direction = "vertical"),
    "f08_removal_bound", 7.0, 2.9)

## ---- 9  knowledge graph: signed relations by entity -------------------------
E <- fread("data/derived/kg_edges.csv")
N <- fread("data/derived/kg_nodes.csv")
inc <- rbind(E[, .(node = subject, weight, trusting, distrusting)],
             E[, .(node = object,  weight, trusting, distrusting)])
sg <- inc[, .(trusting = sum(trusting), distrusting = sum(distrusting),
              neutral = sum(weight - trusting - distrusting)), by = node]
sg <- merge(sg, N[, .(node, degree, type)], by = "node")[order(-degree)][1:14]
sl <- melt(sg[, .(node, degree, trusting, neutral, distrusting)],
           id.vars = c("node", "degree"), variable.name = "valence",
           value.name = "triples")
sl[, node := factor(node, levels = sg[order(degree)]$node)]
sl[, valence := factor(valence, levels = c("distrusting", "neutral", "trusting"))]
fig(ggplot(sl, aes(triples, node, fill = valence)) +
      geom_col(width = 0.7, colour = "grey25", linewidth = 0.25) +
      scale_fill_manual(values = c(distrusting = brewer.pal(9, "Reds")[6],
                                   neutral = "grey78",
                                   trusting = brewer.pal(9, "Blues")[6])) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.04))) +
      labs(x = "extracted relations mentioning the entity", y = NULL),
    "f09_kg_entities", 7.0, 3.8)

## ---- 10  knowledge graph: readable core network ------------------------------
## The full graph is a long tail of single assertions hanging off a few hubs and
## is unreadable at page size. The core is the subgraph induced on the entities
## with degree of at least three, which keeps the hubs and the relations that
## connect them.
suppressPackageStartupMessages(library(igraph))
core <- N[degree >= 3, node]
Ec <- E[subject %in% core & object %in% core]
g <- graph_from_data_frame(Ec[, .(from = subject, to = object, weight, sign)],
                           directed = TRUE)
set.seed(11); L <- layout_with_fr(g, niter = 3000)
## offset the labels of peripheral nodes so hub labels stay legible
ldist <- ifelse(degree(g) >= 5, 0, 1.2)
pal <- c(brewer.pal(9, "Reds")[7], "grey65", brewer.pal(9, "Blues")[7])
ecol <- ifelse(E(g)$sign < 0, pal[1], ifelse(E(g)$sign > 0, pal[3], pal[2]))
png(file.path(OUT, "f10_kg_network.png"), width = 2000, height = 1500, res = 300)
par(mar = c(0, 0, 0, 0), family = "serif")
plot(g, layout = L,
     vertex.size = 4 + 11 * sqrt(degree(g)) / sqrt(max(degree(g))),
     vertex.color = "grey93", vertex.frame.color = "grey40",
     vertex.label.cex = 0.62, vertex.label.color = "black",
     vertex.label.family = "serif", vertex.label.dist = ldist,
     vertex.label.degree = pi / 2,
     edge.color = ecol, edge.curved = 0.12,
     edge.width = 0.6 + 2.2 * E(g)$weight / max(E(g)$weight),
     edge.arrow.size = 0.28)
legend("bottomleft", legend = c("distrusting", "neutral", "trusting"),
       col = pal, lty = 1, lwd = 2.2, bty = "n", cex = 0.6)
dev.off()
cat("  [fig] f10_kg_network\n")
cat(sprintf("[S15] %d figures in %s\n", length(list.files(OUT, "[.]png$")), OUT))
