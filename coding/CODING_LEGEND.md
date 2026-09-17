# Coding legend

Fill one row per comment in `coding_sheet_<YOURINITIALS>.csv`. Save as CSV
(UTF-8) with the same filename when you are done.

**You may type either the number or the full label.** Case, spaces and
trailing punctuation are all forgiven by the reader. Leave `notes` blank
unless something needs flagging for adjudication.

Quoted text, code blocks and links were stripped before you see the comment,
so every word in the `comment` column is that commenter's own. Code what the
comment **says**, not what you think the person believes.

---

## `relevance`

Does the comment express an evaluation, assessment or judgement of an AI system, the organisations that build them, or their consequences?

`1 = relevant  ·  2 = not_relevant`

- **relevant** — The comment evaluates, judges, recommends against, praises, criticises, expresses concern about, or defends an AI system, an AI company, or an effect of AI.
- **not_relevant** — The comment is about something else, or reacts to an AI output without evaluating the system (jokes, captions, prompt-sharing, off-topic chat, pure image reactions).

## `stance`

What stance toward the AI target does the comment express?

`1 = trust  ·  2 = distrust  ·  3 = ambivalent  ·  4 = non_evaluative`

- **trust** — Presents the target as reliable, competent, honest, safe, or beneficial; recommends relying on it; reports it working well.
- **distrust** — Presents the target as unreliable, incompetent, dishonest, dangerous, exploitative, or harmful; warns against relying on it; reports it failing.
- **ambivalent** — Expresses BOTH trusting and distrusting content about the target, or explicitly conditions trust ('fine for X, never for Y').
- **non_evaluative** — Relevant to AI but takes no evaluative stance: factual statements, questions, neutral news relay, technical description.

## `dimension`

Which dimension of (dis)trust is the comment about? Choose the most prominent one.

`1 = competence_reliability  ·  2 = integrity_motives  ·  3 = safety_risk  ·  4 = transparency  ·  5 = societal_impact  ·  6 = not_applicable`

- **competence_reliability** — Accuracy, capability, quality, consistency, hallucination, whether it actually works.
- **integrity_motives** — Honesty and motives of the makers: profit-seeking, astroturfing, broken promises, manipulation, enshittification, pricing.
- **safety_risk** — Harm, security, misuse, psychological risk, guardrails, minors, dependence.
- **transparency** — Openness, explainability, disclosed training data, censorship, black-boxness.
- **societal_impact** — Jobs, art and copyright, education, environment, inequality, the information ecosystem.
- **not_applicable** — Use when stance is non_evaluative or the comment is not relevant.

## `target`

What is the stance directed at?

`1 = specific_model  ·  2 = company  ·  3 = technology_general  ·  4 = community_users  ·  5 = not_applicable`

- **specific_model** — A named system or product: ChatGPT, GPT-5, Claude, Gemini, DeepSeek, Midjourney.
- **company** — An organisation or its leadership: OpenAI, Anthropic, Google, Sam Altman, Musk.
- **technology_general** — AI / LLMs / generative AI as a category, or 'AI' in the abstract.
- **community_users** — The people who use or promote AI, or the discourse itself ('AI bros', this subreddit, hype).
- **not_applicable** — Not relevant, or no stance expressed.

## `incivility_direction`

If the comment is uncivil, who or what is it aimed at?

`1 = at_user  ·  2 = at_third_party  ·  3 = at_ai  ·  4 = none`

- **at_user** — Another participant in the conversation.
- **at_third_party** — A company, a public figure, a group not present ('OpenAI are liars', 'Altman is a fraud').
- **at_ai** — The AI system itself ('ChatGPT is a useless piece of garbage').
- **none** — The comment is civil.

## `inc_*` — the seven incivility columns

Mark **x** (or 1) if the comment contains it, leave blank if not. More than
one may apply. These are coded for **every** comment, relevant or not.

- **inc_name_calling** — Insulting or mocking labels applied to a person, group, or entity ('idiot', 'clown', 'shills', 'braindead').
- **inc_vulgarity** — Profanity or crude language, including censored forms (fuck, shit, F***).
- **inc_aspersion** — Contemptuous dismissal of a person's character, intelligence or motives without a slur ('you clearly have no idea what you're talking about').
- **inc_lying_accusation** — Explicit accusation of lying, bad faith, shilling, astroturfing, or being a bot.
- **inc_pejorative_speech** — Attacking the way something was said rather than its content ('this is the dumbest take I've read all week').
- **inc_identity_attack** — INTOLERANCE. Attack based on race, gender, sexuality, religion, nationality, disability.
- **inc_threat** — INTOLERANCE. Threat of violence or harm, or a wish for harm to befall someone.

---

## Decision rules that settle most hard cases

1. **Criticising an AI is distrust, not incivility.** "GPT-5 hallucinates constantly"
   is `distrust` with no incivility. "GPT-5 is a useless piece of shit" is `distrust`
   **and** `inc_vulgarity` with direction `at_ai`.
2. **Trust is not positive sentiment.** An excited comment about an image it made
   is `not_relevant` unless it says something about the system being good, reliable,
   or worth relying on.
3. **Ambivalent is a real category.** "Great for boilerplate, never for anything legal"
   is `ambivalent`, not trust and not distrust.
4. **If `relevance` = not_relevant**, set `stance` = non_evaluative and both
   `dimension` and `target` = not_applicable. Still code the `inc_*` columns.
5. **Sarcasm carries its intended meaning**, not its literal one.
6. When genuinely torn, pick the more conservative option (the one claiming less)
   and write a word in `notes`.
