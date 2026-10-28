# Multi-turn benchmark on iPhone18,2, iOS 27.0.1

92 conversation runs, $12.18 spent. Router: on-device classifier, advanced-b instructions + exact-answer detector. Cloud model: claude-sonnet-5-5. On-device context: 8192 tokens. Judge: claude-opus-5-5.

## All conversations (36 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 83% | 61% | 4.15 | $0.031 | 28% |
| Always on-device | 54% | 11% | 2.96 | $0.000 | 100% |
| Always Claude | 97% | 86% | 4.66 | $0.038 | 0% |

- **Follow-ups:** 50 of 53 stayed on the model that answered before (passed 94% when they stayed, 100% when they moved); 1 of 5 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 8 of 8 private turns, plus 0 others. Turns building on a private turn passed 27% on the router vs 100% always on Claude; the router sent 0 of 15 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 13, always claude 0. Recall questions passed: router 100%, always on-device 61%, always claude 100%.
- **Failures:** 10 of 10 turns with injected failures were still answered (7 passed, 3 by falling back to on-device); 0 faults didn't fire because the turn didn't go to Claude.
- 4 grades failed because the judge errored; they count as failing.

## Held-out (9 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 76% | 57% | 4.00 | $0.032 | 24% |
| Always on-device | 47% | 14% | 2.65 | $0.000 | 100% |
| Always Claude | 94% | 71% | 4.71 | $0.037 | 0% |

- **Follow-ups:** 14 of 14 stayed on the model that answered before (passed 93% when they stayed, n/a when they moved); 0 of 2 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 2 of 2 private turns, plus 0 others. Turns building on a private turn passed 0% on the router vs 100% always on Claude; the router sent 0 of 4 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 5, always claude 0. Recall questions passed: router 100%, always on-device 40%, always claude 100%.
- **Failures:** 3 of 3 turns with injected failures were still answered (2 passed, 1 by falling back to on-device); 0 faults didn't fire because the turn didn't go to Claude.
- 4 grades failed because the judge errored; they count as failing.

## Tuning (27 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 85% | 62% | 4.19 | $0.031 | 30% |
| Always on-device | 56% | 10% | 3.06 | $0.000 | 100% |
| Always Claude | 98% | 90% | 4.64 | $0.039 | 0% |

- **Follow-ups:** 36 of 39 stayed on the model that answered before (passed 94% when they stayed, 100% when they moved); 1 of 3 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 6 of 6 private turns, plus 0 others. Turns building on a private turn passed 36% on the router vs 100% always on Claude; the router sent 0 of 11 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 8, always claude 0. Recall questions passed: router 100%, always on-device 67%, always claude 100%.
- **Failures:** 7 of 7 turns with injected failures were still answered (5 passed, 2 by falling back to on-device); 0 faults didn't fire because the turn didn't go to Claude.