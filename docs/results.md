# Results

How well HybridRouter routes, measured on an iPhone 17 Pro Max: answer quality versus cost against fixed strategies, the routing changes since 0.2.0, classifier accuracy, and speed and cost per route.
## Quality vs cost

Does routing keep answers good while spending less? On an iPhone 17 Pro Max, each of 150 held-out prompts (chat, trip planning and pasted documents, none used while tuning the router) was answered on-device, by Claude Sonnet, by Claude Opus and by Meta's Muse Wonder. Claude Opus 5.5 graded every answer, without knowing which model wrote it, as good enough or not. Each strategy is then scored on the answers it would have given:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="images/quality-dark.svg">
    <img src="images/quality-light.svg" width="100%" alt="Answers judged good enough against cost per 100 prompts, with the router as it ships today. Always on-device: 62% at $0. Random routing with the router's mix: 87% at $0.50. HybridRouter: 95% at $0.62. Always Sonnet: 97% at $0.71. Always Opus: 100% at $1.51. Always Muse Wonder: 98% at $1.88. Perfect routing: 99% at $0.42.">
  </picture>
</p>

Numbers are for the router as it ships today, with the [exact-answer detector](#routing-improvements). The 0.2.0 router, measured before the detector, is kept for comparison.

| Strategy | Answers good enough | Cost per 100 prompts | Stays on the phone |
|---|---|---|---|
| **HybridRouter** | **95%** | **$0.62** | **29%** |
| HybridRouter 0.2.0, before the detector | 91% | $0.61 | 37% |
| Always on-device | 62% | $0 | 100% |
| Always Claude Sonnet | 97% | $0.71 | 0% |
| Always Claude Opus (reference) | 100% | $1.51 | 0% |
| Always Muse Wonder (Meta) | 98% | $1.88 | 0% |
| Random, same mix as the router | 87% | $0.50 | 29% |
| Perfect routing (cheapest route that passed) | 99% | $0.42 | 62% |

- **The router beats chance.** It closes 94% of the quality gap between always-on-device and always-Claude, 8 points above random routing that keeps the same share on the phone.
- **Close to Sonnet quality for less:** 13% cheaper than always-Sonnet for 2 points less, while keeping 29% of messages on the phone. Perfect routing would keep 99% for 41% less than Sonnet, so there's still headroom.
- **Against always-Opus it's 59% cheaper, but mostly because Sonnet costs half as much.** With Opus as the router's Claude tier (the same routing decisions, scored on the Opus answers), it would pass 98% at $1.32 per 100 prompts: 13% cheaper than always-Opus. So routing itself saves about 13% whichever Claude sits on top, and perfect routing would save 42% with Opus at no loss in quality.
- **Muse Wonder matches the top tier but costs the most and answers slowest.** It passed 98%, between Sonnet and Opus, and got 4 prompts right that Sonnet missed. But it reasons at length before answering, so it costs more than Opus at the same list price ($1.88 per 100 prompts, 27% more output) and took a median 9.3 s to the first word, against 2.2 s for Sonnet; Meta's Anthropic-compatible endpoint sends the whole reply at once. With Muse as the router's cloud tier, the router would pass 97% at $1.58 per 100 prompts.
- **Most of the remaining gap is over-routing.** 53 of the 150 prompts went to Claude when the on-device answer was already good enough, mostly summaries, rewrites, explainers and short code.
- **Few quality misses are left.** The router kept 3 prompts on-device that then failed, down from 9 before the detector, which sends counting, date and arithmetic questions to the cloud.

**Checking the judge.** A model grading models can be wrong or favor its own answers, so 40 verdicts, mixed across routes and passes and fails, were hand-checked blind to which model wrote each answer. The checker agreed on 35 and disagreed on 1, a borderline time-zone answer the judge failed as misleading: 97% of the calls they took a side on, or 88% counting the 4 they weren't sure about.

Caveats: Apple Cloud isn't in this run, because the Private Cloud Compute entitlement is pending, so its turns went to Claude as in the shipped app. If your team has the entitlement, you can add Apple Cloud to these results in about 15 minutes (Settings › Developer › Answer quality › Add Apple Cloud): see [issue #1](https://github.com/jaichaudhry/HybridRouter/issues/1). Muse Wonder was added afterwards from a Mac (its answers don't depend on the device) and graded by the same judge; the hand check above predates it, and a Claude judge may favor Claude-style answers. Its first pass exposed an app bug: told it was one of three models, Muse signed replies "I'm Muse Wonder", which the judge failed as an invented identity. The note now says to mention the model only when asked, and Muse was re-run; the other models had almost never repeated it (Sonnet once in 175 answers, Opus never), so they weren't. Costs are API list prices for answers only; the runs reported here cost $13.46 in total, judging included. Full answers, verdicts and every misrouted prompt are in [`Evals/results/`](../Evals/results/2026-10-14-iphone-quality-muse.md); the current router's choices are in `2026-10-15-iphone-quality-with-detector.json`, the 0.2.0 routing plus the exact-answer rule, which matches the iPhone replays exactly.

## Routing improvements

The benchmark ran once, with the 0.2.0 router. Every prompt there was answered on every route and graded, so a routing change can be measured for free by replaying only the router over the saved answers (**Settings › Developer › Answer quality › Replay routing**). Changes are tuned on those 175 development prompts, then confirmed once on [150 fresh test prompts](../Evals/quality_testset.json) answered on the same iPhone.

| On an iPhone 17 Pro Max | Held-out (150) | Test set (150) |
|---|---|---|
| 0.2.0 router | 91% at $0.61 per 100 | 89% at $0.38 per 100 |
| **+ exact-answer detector** (now on) | **95%, +4.0 points (+1.3 to +7.3), 3% dearer** | **95%, +6.0 points (+2.7 to +10.0), 4% dearer** |
| "What does it need?" classifier + detector (experimental) | 87%, −4.7 points (−10.7 to +1.3), 28% cheaper | 89%, +0.0 points (−6.0 to +6.0), 23% cheaper |

Intervals are 95% paired bootstrap ranges.
- **The exact-answer detector** is a few lines of pattern matching that runs before the classifier and sends counting, arithmetic, date and conversion questions to the cloud model. The classifier labels these "simple" because they sound easy, yet the on-device model got about half of them wrong (miscounted letters in "Mississippi", the wrong weekday 45 days after a Friday). It's on in the app and opt-in in HybridRouterKit (`Router(detectsExactAnswers: true)`).
- **The "what does it need?" classifier** asks the on-device model what a prompt needs instead of how complex it sounds. It's consistently cheaper, but its effect on quality is unclear, so it stays an experiment, a candidate for a future "save money" setting.
- **What didn't work:** asking the on-device model to check its own answers. It called 94% of them trustworthy, wrong ones included. Learned routers on 175 examples weren't better than the classifier either. Giving the on-device model tools for exact answers (a calculator, date maths, time zones, counting and unit conversion) instead of sending those questions to the cloud: it passed 11 of 20 of them against Sonnet's 19, fewer of the other prompts, and slowed every reply from 1.9 to 7.0 s, so the tools were removed ([details](../Evals/results/2026-10-16-on-device-tools.md)). Details are in [`Evals/results/2026-10-15-routing-replays.md`](../Evals/results/2026-10-15-routing-replays.md).

## Speech-to-text

Apple's on-device `SpeechTranscriber`, on 20 prompts read aloud on an iPhone (Settings › Developer › Speech check):

| Real word errors | Same privacy decision as typed | Same route as typed | Final text after Stop |
|---|---|---|---|
| 3 of 154 words (1.9%) | 20 of 20 | 19 of 20, then 20 of 20 after the speech patterns | 0.06 s (median) |

Formatting such as "17×24" for "17 times 24" isn't counted as an error. Details: [`Evals/results/2026-10-19-iphone-speech-check.md`](../Evals/results/2026-10-19-iphone-speech-check.md).

## Routing accuracy

Routing accuracy against 50 hand-labeled prompts in `Evals/classifier_benchmark.json`. Apple ships different on-device model variants, and a prompt tuned on one doesn't transfer to the other, so the classifier uses instructions tuned per variant:

| Device | On-device model | Routed as labeled | Median time to classify |
|---|---|---|---|
| iPhone 17 Pro Max, iOS 27.0.1 | AFM 3 Core Advanced (8K context) | **46/50** | **628 ms** |
| MacBook Pro M1 Max, macOS 27.0 | AFM 3 Core (4K context) | **48/50** | ~900 ms |

Every miss routes one level higher than labeled (the safer direction), never lower.

Speed and cost per route on an iPhone 17 Pro Max (iOS 27.0.1), median of three prompts each (Settings › Developer › Measure routes):

| Route | Model | First token | Tokens/sec | Cost per reply |
|---|---|---|---|---|
| On-device | AFM 3 Core Advanced | 368 ms | 63 | $0 |
| Apple Cloud | Private Cloud Compute | not measured yet (needs Apple's entitlement) | | |
| Claude | Sonnet 5.5 | 1,030 ms | 89 | $0.0047 |

Route mix for each scenario's sample conversation on Auto, same iPhone, with Apple Cloud simulated on-device while the Private Cloud Compute entitlement is pending. Routing decisions and Claude costs are real; Apple Cloud has no API cost either way.

| Scenario | On-device | Apple Cloud | Claude | Cost | All on Claude | Saved |
|---|---|---|---|---|---|---|
| Trip Planner (7 turns) | 29% | 43% | 29% | $0.034 | $0.054 | 37% |
| Chat (3 turns) | 33% | 33% | 33% | $0.0058 | $0.0078 | 26% |

Without Apple Cloud at all, its turns move up to Claude: the Trip Planner then ran 86% on Claude for $0.092. The same set also runs as an Apple [Evaluations](https://developer.apple.com/documentation/evaluations) framework evaluation (`Evals/AppleEvaluationTests.swift`), which scores 0.96 and writes an `.xcevalresult` you can open in Xcode.

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
