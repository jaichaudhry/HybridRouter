# Speech check: Apple's on-device speech-to-text

20 prompts read aloud on an iPhone (iOS 27) into `SpeechTranscriber` (progressive transcription, with the model and place names as contextual strings), from **Settings › Developer › Speech check**. Raw data: `2026-10-19-iphone-speech-check.json`. Its `wordErrors` fields predate the formatting-aware scorer; the numbers below are re-scored with `TranscriptScore` as it is now.

| | Result |
|---|---|
| Real word errors | **3 of 154 words (1.9%)**; 17 of 20 prompts exact |
| Formatting differences, not counted | "17×24", "72°F", "$250", "Summarise" |
| Same privacy decision as typed | **20 of 20**, including a spoken phone number, a health detail and an email address |
| Same exact-answer rule as typed | 18 of 20 before the speech patterns, 20 of 20 after |
| Same route as typed | 19 of 20 (the one difference: typed "17 times 24" wasn't caught by the exact-answer rule; spoken "17×24" was) |
| Text final after tapping Stop | median **0.06 s** |
| First words on screen | 1.2–2.1 s from tapping the mic, including the pause before speaking |

## The three errors

| Said | Heard | Effect |
|---|---|---|
| How many **r's** are in the word strawberry? | How many **hours** are in the word strawberry? | Now caught as counting by "how many … in the word …" |
| Text my number, 415-555-0132, **to** Sam. | Text my number 415-555-0132 Sam | None |
| Email the itinerary to **jai**@example.com. | Email the itinerary to **j**@example.com | None: still an email address, so still private |

## What changed because of it

- The exact-answer rule catches spoken letter counting and word-form arithmetic ("17 times 24"). It changes nothing on the 325 benchmark prompts.
- `TranscriptScore` treats symbols, units, currencies, number words and British spellings as equal, so only real mistakes count.
- `DictationTranscriber` and WhisperKit weren't needed for this accuracy; the screen can still compare Apple's two models on the saved audio.
