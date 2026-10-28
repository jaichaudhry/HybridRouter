# Multi-turn benchmark on iPhone18,2, iOS 27.0.1

92 conversation runs, $9.40 spent. Router: on-device classifier, advanced-b instructions + exact-answer detector. Cloud model: claude-sonnet-5-5. On-device context: unknown. Judge: claude-opus-5-5.

## All conversations (36 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 77% | 25% | 3.85 | $0.026 | 45% |
| Always on-device | 64% | 14% | 3.26 | $0.000 | 100% |
| Always Claude | 98% | 89% | 4.72 | $0.036 | 0% |

- **Follow-ups:** 36 of 53 stayed on the model that answered before (passed 89% when they stayed, 47% when they moved); 1 of 5 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 8 of 8 private turns, plus 0 others. Turns building on a private turn passed 27% on the router vs 100% always on Claude; the router sent 7 of 15 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 0, always claude 0. Recall questions passed: router 87%, always on-device 83%, always claude 100%.
- **Failures:** 7 of 7 turns with injected failures were still answered (5 passed, 2 by falling back to on-device); 3 faults didn't fire because the turn didn't go to Claude.

## Held-out (9 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 71% | 14% | 3.59 | $0.024 | 50% |
| Always on-device | 62% | 14% | 3.18 | $0.000 | 100% |
| Always Claude | 97% | 86% | 4.74 | $0.035 | 0% |

- **Follow-ups:** 11 of 14 stayed on the model that answered before (passed 91% when they stayed, 0% when they moved); 0 of 2 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 2 of 2 private turns, plus 0 others. Turns building on a private turn passed 25% on the router vs 100% always on Claude; the router sent 2 of 4 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 0, always claude 0. Recall questions passed: router 80%, always on-device 100%, always claude 100%.
- **Failures:** 3 of 3 turns with injected failures were still answered (2 passed, 1 by falling back to on-device); 0 faults didn't fire because the turn didn't go to Claude.

## Tuning (27 conversations)

| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |
|---|---|---|---|---|---|
| Router | 79% | 29% | 3.94 | $0.027 | 43% |
| Always on-device | 65% | 14% | 3.29 | $0.000 | 100% |
| Always Claude | 98% | 90% | 4.72 | $0.036 | 0% |

- **Follow-ups:** 25 of 39 stayed on the model that answered before (passed 88% when they stayed, 57% when they moved); 1 of 3 harder follow-ups moved to a larger model.
- **Privacy:** no leaks; the guard flagged 6 of 6 private turns, plus 0 others. Turns building on a private turn passed 27% on the router vs 100% always on Claude; the router sent 5 of 11 of them to Claude, which saw the private turns as placeholders.
- **Long chats:** the router moved up 0 times; turns answered from recent turns only: router 0, always on-device 0, always claude 0. Recall questions passed: router 89%, always on-device 78%, always claude 100%.
- **Failures:** 4 of 4 turns with injected failures were still answered (3 passed, 1 by falling back to on-device); 3 faults didn't fire because the turn didn't go to Claude.