# On-device tools for exact answers (2026-10-16): tried and removed

The exact-answer detector sends counting, arithmetic, date and conversion questions to the cloud
model. This experiment tried keeping them on the phone instead, by giving Apple's on-device model
five Swift tools: a calculator, date maths, time-zone conversion, letter and word counting, and unit
conversion. The 175 development prompts were re-answered on an iPhone 17 Pro Max with the tools
available and graded by the same Claude Opus judge (`2026-10-16-iphone-quality-tools.json`, column
`onDeviceTools`).

| 150 held-out prompts | On-device | On-device with tools | Claude Sonnet |
|---|---|---|---|
| All prompts passing | 93 | 86 | 146 |
| Exact-answer prompts passing (20) | 9 | 11 | 19 |
| Median reply time | 1.9 s | 7.0 s | 5.3 s |

- The model often called the right tool, but passed wrong inputs or used only part of the result:
  12 vacation days instead of 9, a scaled recipe that left the pasta unscaled, an arrival time
  without "the next day", a compound-interest total of $70 million.
- Every reply got slower, including ones that used no tool, because the tool descriptions are
  processed with every message.
- 18 prompts that passed without tools failed with them, and 11 went the other way, many of them
  prompts that needed no tool. Part of that is run-to-run variation in the on-device model's
  answers, so the overall drop is noisy, but there is no sign the tools helped.

Sending these questions to the cloud model (19 of 20 pass) works better, so the tools weren't kept.
The JSON's `onDeviceTools` column comes from that removed code, so current builds can't load it.
