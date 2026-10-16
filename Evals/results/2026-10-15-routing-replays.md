# Routing replays on iPhone (2026-10-15)

Each replay reruns only the router (iPhone 17 Pro Max, iOS 27.0.1, AFM 3 Core Advanced) over
saved answers, so the answers and grades are unchanged. Development prompts are the 0.2.0 results
(`2026-10-14-iphone-quality-muse.json`); the test set is `2026-10-15-iphone-quality-testset.json`,
used once to confirm the two candidates. Intervals are 95% paired bootstrap ranges against the
routing each file was saved with (0.2.0's `advanced-b` classifier, no detector).

| Router | Held-out (150) | Test set (150) |
|---|---|---|
| `advanced-b` (0.2.0) | 91.3% at $0.61 per 100; replay changed 0 of 175 routes | 89.3% at $0.38 per 100 |
| **`advanced-b` + exact-answer detector** | **95% at $0.62: +4.0 points (+1.3 to +7.3), 3% dearer (1% to 6%)** | **95.3%: +6.0 points (+2.7 to +10.0), 4% dearer (2% to 7%)** |
| `needs-a` | 86% at $0.42: −5.3 points (−11.3 to 0), 31% cheaper (21% to 43%) | not run |
| `needs-a` + detector | 87% at $0.43: −4.7 points (−10.7 to +1.3), 28% cheaper (18% to 40%) | +0.0 points (−6.0 to +6.0), 23% cheaper (12% to 35%) |

All rows are copied from the summaries the app exported. On the test set, the exports' lines were:

> Router replayed on the saved answers. Classifier: on-device classifier, advanced-b instructions + exact-answer detector (replayed on iPhone18,2, iOS 27.0.1).
>
> Test set vs saved routing: +6.0 points (+2.7 to +10.0), 4% dearer (2% dearer to 7% dearer), 19 of 150 prompts routed differently
>

> Router replayed on the saved answers. Classifier: on-device classifier, needs-a instructions + exact-answer detector (replayed on iPhone18,2, iOS 27.0.1).
>
> Test set vs saved routing: +0.0 points (-6.0 to +6.0), 23% cheaper (35% cheaper to 12% cheaper), 57 of 150 prompts routed differently
>
