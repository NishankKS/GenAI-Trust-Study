## ---------------------------------------------------------------------------
## S2 -- THE CODEBOOK, AS A SINGLE SOURCE OF TRUTH
##
## This file is the only definition of the measurement instrument. It is used
## three times, and never retyped:
##   1. rendered to docs/codebook.md, the paper's appendix and the human
##      coders' reference (R/02_render_codebook.R);
##   2. pasted verbatim into the LLM annotation prompts (R/04_llm_annotate.R);
##   3. used to build the ellmer type schema, so the model is structurally
##      incapable of returning an off-codebook label.
##
## Conceptual anchors:
##   Trust      Mayer, Davis & Schoorman (1995); Lee & See (2004);
##              Jacovi, Marasovic, Miller & Goldberg (2021)
##   Incivility Coe, Kenski & Rains (2014); Muddiman (2017); Rossini (2022)
## ---------------------------------------------------------------------------

CODEBOOK <- list(

  relevance = list(
    label = "Relevance",
    question = paste(
      "Does the comment express an evaluation, assessment or judgement of an AI",
      "system, the organisations that build them, or their consequences?"),
    rationale = paste(
      "The largest threads in r/ChatGPT are image-generation games in which users",
      "post outputs and react to them. Such comments are on-platform but carry no",
      "evaluative stance toward AI. Scoring them for trust would fill the",
      "denominator with noise and deflate every prevalence estimate."),
    levels = list(
      relevant = list(
        def = "The comment evaluates, judges, recommends against, praises, criticises, expresses concern about, or defends an AI system, an AI company, or an effect of AI.",
        yes = c("\"Gemini is much better at image creation\"",
                "\"You guys know you can just not use an LLM, right?\"",
                "\"It doesn't benefit anyone not to call out astroturfing when you see it\" (in an OpenAI-conduct thread)"),
        no  = c("A caption for a generated image", "A prompt someone is sharing")),
      not_relevant = list(
        def = "The comment is about something else, or reacts to an AI output without evaluating the system (jokes, captions, prompt-sharing, off-topic chat, pure image reactions).",
        yes = c("\"Not the worst one\" under a generated picture",
                "\"why are you using AI to cut a sandwich?\" (joke, no assessment)"),
        no  = c("Any comment saying an AI is good/bad/unsafe/overhyped")))
  ),

  stance = list(
    label = "Trust stance",
    question = "What stance toward the AI target does the comment express?",
    rationale = paste(
      "Trust is not sentiment. A comment can be enthusiastic and distrusting at",
      "once ('it's incredible, and that's exactly why it scares me'), so the scheme",
      "must admit ambivalence rather than force a positive/negative axis."),
    levels = list(
      trust = list(
        def = "Presents the target as reliable, competent, honest, safe, or beneficial; recommends relying on it; reports it working well.",
        yes = c("\"Sticking with it because it works. It has been a game changer at my job.\"",
                "\"Claude is genuinely good at refactoring, I trust its diffs now\"")),
      distrust = list(
        def = "Presents the target as unreliable, incompetent, dishonest, dangerous, exploitative, or harmful; warns against relying on it; reports it failing.",
        yes = c("\"It confidently made up three citations, I can't use it for anything that matters\"",
                "\"They're astroturfing this sub and that tells you what they are\"")),
      ambivalent = list(
        def = "Expresses BOTH trusting and distrusting content about the target, or explicitly conditions trust ('fine for X, never for Y').",
        yes = c("\"Great for boilerplate, absolutely not for anything legal\"")),
      non_evaluative = list(
        def = "Relevant to AI but takes no evaluative stance: factual statements, questions, neutral news relay, technical description.",
        yes = c("\"GPT-5 came out in August\"", "\"Does anyone know the context limit?\"")))
  ),

  dimension = list(
    label = "Trust dimension",
    question = "Which dimension of (dis)trust is the comment about? Choose the most prominent one.",
    rationale = paste(
      "The Mayer-Davis-Schoorman triad (ability, benevolence, integrity) adapted to",
      "AI. Separating these is what turns 'people distrust AI' into a finding:",
      "distrust of a model's accuracy is a different object from distrust of a",
      "company's motives, and the two behave differently across venues."),
    levels = list(
      competence_reliability = list(
        def = "Accuracy, capability, quality, consistency, hallucination, whether it actually works.",
        yes = c("\"it hallucinates half the API\"")),
      integrity_motives = list(
        def = "Honesty and motives of the makers: profit-seeking, astroturfing, broken promises, manipulation, enshittification, pricing.",
        yes = c("\"they promised open weights and then didn't\"")),
      safety_risk = list(
        def = "Harm, security, misuse, psychological risk, guardrails, minors, dependence.",
        yes = c("\"it should not be doing therapy on teenagers\"")),
      transparency = list(
        def = "Openness, explainability, disclosed training data, censorship, black-boxness.",
        yes = c("\"but yeah deepseek is censored\"")),
      societal_impact = list(
        def = "Jobs, art and copyright, education, environment, inequality, the information ecosystem.",
        yes = c("\"it's going to gut junior hiring\"")),
      not_applicable = list(
        def = "Use when stance is non_evaluative or the comment is not relevant.",
        yes = character(0)))
  ),

  target = list(
    label = "Target of the stance",
    question = "What is the stance directed at?",
    levels = list(
      specific_model  = list(def = "A named system or product: ChatGPT, GPT-5, Claude, Gemini, DeepSeek, Midjourney.", yes = character(0)),
      company         = list(def = "An organisation or its leadership: OpenAI, Anthropic, Google, Sam Altman, Musk.", yes = character(0)),
      technology_general = list(def = "AI / LLMs / generative AI as a category, or 'AI' in the abstract.", yes = character(0)),
      community_users = list(def = "The people who use or promote AI, or the discourse itself ('AI bros', this subreddit, hype).", yes = character(0)),
      not_applicable  = list(def = "Not relevant, or no stance expressed.", yes = character(0)))
  ),

  incivility = list(
    label = "Incivility (multi-label)",
    question = "Which of these features does the comment contain? Mark all that apply.",
    rationale = paste(
      "Following Rossini (2022), incivility (a violation of politeness norms) is",
      "kept separate from intolerance (attacks on identity, threats), because the",
      "two have different normative implications for public discourse. Following",
      "Muddiman (2017), the direction of the attack is recorded separately:",
      "calling another user an idiot and calling ChatGPT garbage are not the same",
      "phenomenon, and conflating them is the standard flaw in this literature.",
      "NOTE: quoted text has already been stripped from the comment, so anything",
      "present is the commenter's own words."),
    levels = list(
      name_calling      = list(def = "Insulting or mocking labels applied to a person, group, or entity ('idiot', 'clown', 'shills', 'braindead').", yes = character(0)),
      vulgarity         = list(def = "Profanity or crude language, including censored forms (fuck, shit, F***).", yes = character(0)),
      aspersion         = list(def = "Contemptuous dismissal of a person's character, intelligence or motives without a slur ('you clearly have no idea what you're talking about').", yes = character(0)),
      lying_accusation  = list(def = "Explicit accusation of lying, bad faith, shilling, astroturfing, or being a bot.", yes = character(0)),
      pejorative_speech = list(def = "Attacking the way something was said rather than its content ('this is the dumbest take I've read all week').", yes = character(0)),
      identity_attack   = list(def = "INTOLERANCE. Attack based on race, gender, sexuality, religion, nationality, disability.", yes = character(0)),
      threat            = list(def = "INTOLERANCE. Threat of violence or harm, or a wish for harm to befall someone.", yes = character(0)))
  ),

  incivility_direction = list(
    label = "Direction of incivility",
    question = "If the comment is uncivil, who or what is it aimed at?",
    levels = list(
      at_user       = list(def = "Another participant in the conversation.", yes = character(0)),
      at_third_party= list(def = "A company, a public figure, a group not present ('OpenAI are liars', 'Altman is a fraud').", yes = character(0)),
      at_ai         = list(def = "The AI system itself ('ChatGPT is a useless piece of garbage').", yes = character(0)),
      none          = list(def = "The comment is civil.", yes = character(0)))
  )
)

## ---- machine-readable level vectors, used by the schema and the coding sheet
cb_levels <- function(field) names(CODEBOOK[[field]]$levels)

## ---- the block that is pasted verbatim into every annotation prompt --------
## `compact = TRUE` drops the rationale paragraphs, which exist to orient a
## human coder and carry no decision rule. The category definitions and the
## worked examples -- everything a labelling decision actually turns on -- are
## kept verbatim. This matters because the block is re-sent on every API
## request: at an 8,000 token/minute ceiling the rationale text alone was
## costing roughly 40% of the study's total throughput.
codebook_prompt_block <- function(fields = c("relevance","stance","dimension",
                                             "target","incivility","incivility_direction"),
                                  compact = FALSE) {
  out <- character(0)
  for (f in fields) {
    cb <- CODEBOOK[[f]]
    out <- c(out, sprintf("## %s (field: %s)", cb$label, f), cb$question)
    if (!is.null(cb$rationale) && !compact) out <- c(out, paste("Why this matters:", cb$rationale))
    for (lv in names(cb$levels)) {
      L <- cb$levels[[lv]]
      line <- sprintf("- %s: %s", lv, L$def)
      if (length(L$yes)) line <- paste0(line, " EXAMPLES: ", paste(L$yes, collapse = " | "))
      if (!compact && !is.null(L$no) && length(L$no))
        line <- paste0(line, " NOT THIS: ", paste(L$no, collapse = " | "))
      out <- c(out, line)
    }
    out <- c(out, "")
  }
  paste(out, collapse = "\n")
}
