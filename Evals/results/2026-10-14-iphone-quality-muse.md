# Answer quality on iPhone18,2, iOS 27.0.1 (175 prompts, $13.46)

### Held-out (150 prompts)

| Strategy | Answers passed | Mean score | Cost per 100 prompts | Sent to Claude |
|---|---|---|---|---|
| **HybridRouter** | 91% | 4.40 | $0.61 | 63% |
| Always on-device | 62% | 3.25 | $0.00 | 0% |
| Always Claude Sonnet | 97% | 4.77 | $0.71 | 100% |
| Always Claude Opus | 100% | 4.94 | $1.51 | 100% |
| Always Muse Wonder | 98% | 4.69 | $1.88 | 0% |
| Random, same mix | 84% | 4.22 | $0.45 | 63% |
| Oracle (cheapest good-enough) | 99% | 4.40 | $0.42 | 38% |

Router vs the cheapest good-enough route: 91 matched, 48 over-routed (paid more than needed), 9 under-routed (answer failed where a bigger model passed), 2 no route passed.
It recovers 83% of the quality gap between always-on-device and always-Claude.

| # | Prompt | Router | Cheapest good-enough |
|---|---|---|---|
| 112 | What causes the seasons on Earth? | Claude Sonnet | On-device |
| 113 | Make a 30-minute beginner bodyweight workout with a warm-up and cool-down. | Claude Sonnet | On-device |
| 116 | Create a weekly dinner plan for a vegetarian family of four who don't eat eggs, … | Claude Sonnet | On-device |
| 117 | What are the pros and cons of an electric car versus a hybrid for someone who dr… | Claude Sonnet | On-device |
| 118 | Write a Python function that checks whether a string is a palindrome, ignoring s… | Claude Sonnet | On-device |
| 120 | What does git rebase do, and when should I use it instead of merge? | Claude Sonnet | On-device |
| 125 | Explain why you should switch doors in the Monty Hall problem, in a way a skepti… | Claude Sonnet | On-device |
| 128 | Design a database schema for a library with books, members, loans and reservatio… | Claude Sonnet | On-device |
| 133 | Summarize the plot of Romeo and Juliet in three sentences. | Claude Sonnet | On-device |
| 135 | Is 1,001 a prime number? | Claude Sonnet | On-device |
| 136 | How many r's are in the word 'strawberry'? | On-device | Claude Sonnet |
| 137 | If today is Tuesday, what day of the week will it be 100 days from now? | On-device | Claude Sonnet |
| 140 | Rewrite this to be clearer: 'Due to the fact that the meeting was rescheduled, t… | Claude Sonnet | On-device |
| 145 | Explain what inflation is and why central banks raise interest rates to fight it… | Claude Sonnet | On-device |
| 146 | Two trains leave cities 300 miles apart at the same time, heading toward each ot… | Claude Sonnet | On-device |
| 147 | What's the difference between machine learning and traditional programming? | Claude Sonnet | On-device |
| 149 | Write a persuasive but honest paragraph asking my manager for a raise. This year… | Claude Sonnet | On-device |
| 151 | What's the usual time difference between New York and London? | On-device | Claude Sonnet |
| 154 | Translate 'Can I have the check, please?' into Spanish, French and Italian. | On-device | Claude Sonnet |
| 163 | Plan a kid-friendly weekend in San Diego for a family with a 5- and an 8-year-ol… | Claude Sonnet | On-device |
| 167 | How can I avoid jet lag on a flight from Los Angeles to Sydney? | Claude Sonnet | On-device |
| 170 | My passport expires in 4 months and I'm flying to Thailand next month. Is that a… | Claude Sonnet | On-device |
| 174 | Is it safe to travel to Mexico City right now, and which precautions actually ma… | Claude Sonnet | On-device |
| 176 | My hotel overcharged me €180 and the front desk won't fix it. I paid by credit c… | Claude Sonnet | On-device |
| 182 | Rewrite this itinerary as a friendly text to my parents: 'Day 1 Lisbon arrive 2p… | Claude Sonnet | On-device |
| 183 | From this booking, list each flight number with its date and seat: 'Booking ABC1… | Claude Sonnet | On-device |
| 185 | What health precautions should I think about for a trip to Kenya? | Claude Sonnet | On-device |
| 186 | Recommend three apps for planning a trip. | Claude Sonnet | On-device |
| 193 | Summarize this in one sentence: 'The city council voted 7–2 on Tuesday to extend… | Claude Sonnet | On-device |
| 194 | Fix the grammar: 'Me and him was going to the store, but they was closed so we g… | On-device | Claude Sonnet |
| 197 | Summarize this article in three bullet points: 'A two-year study of 1,600 employ… | Claude Sonnet | On-device |
| 198 | Turn these meeting notes into action items with owners and dates: 'Sam will upda… | Claude Sonnet | On-device |
| 200 | Rewrite this complaint email to be firm but polite: 'This is the third time your… | Claude Sonnet | On-device |
| 202 | Give me the TL;DR of these release notes: 'Version 4.2: Offline mode now syncs e… | Claude Sonnet | On-device |
| 204 | Turn these bullets into a short professional project update: - API migration 80%… | Claude Sonnet | On-device |
| 205 | What are the cancellation terms here? 'Members may cancel at any time. Cancellat… | Claude Sonnet | On-device |
| 209 | Summarize the risks for the tenant in this lease excerpt: 'Section 4. Renewal: T… | Claude Sonnet | On-device |
| 210 | What should I ask about this SaaS contract before signing? 'Term: 36 months. Fee… | Claude Sonnet | On-device |
| 212 | Count the words in this sentence: 'The quick brown fox jumps over the lazy dog.' | On-device | Claude Sonnet |
| 213 | What's the main idea of this paragraph? 'Bees pollinate roughly a third of the c… | Claude Sonnet | On-device |
| 214 | Do these numbers add up? 'Subtotal $84.50, tax 8% $6.76, tip $15.00, total $105.… | Claude Sonnet | On-device |
| 215 | Which date is earlier: 03/04/2026 written in the US, or 03/04/2026 written in th… | On-device | Claude Sonnet |
| 216 | Extract every date and what happens on it: 'Applications open Nov 3. Interviews … | Claude Sonnet | On-device |
| 217 | Summarize this email thread in two sentences: 'Dana (Mon): Can we move the launc… | Claude Sonnet | On-device |
| 224 | Does the conclusion follow? 'Sales rose 20% after we redesigned the website in M… | Claude Sonnet | On-device |
| 225 | Summarize these reviews into the top complaints and the main praise: '1) Love th… | Claude Sonnet | On-device |
| 227 | Scale this recipe from 4 servings to 6: '300 g pasta, 2 cloves garlic, 60 ml oli… | On-device | Claude Sonnet |
| 228 | This receipt says: 'Coffee $4.50 x3, Muffin $3.25 x2, 10% discount applied to to… | Claude Sonnet | On-device |
| 229 | Write a headline for this: 'After a decade of decline, the town's main street is… | Claude Sonnet | On-device |
| 234 | Convert this JavaScript to Swift: const evens = nums.filter(n => n % 2 === 0).ma… | Claude Sonnet | On-device |
| 236 | Explain the difference between TCP and UDP, with an example of when to use each. | Claude Sonnet | On-device |
| 239 | Outline an honest reference letter for a former intern who was reliable but need… | Claude Sonnet | On-device |
| 242 | Is it true that we only use 10% of our brains? | Claude Sonnet | On-device |
| 243 | Explain the theory of relativity in exactly three bullet points. | Claude Sonnet | On-device |
| 246 | Make this message sound less passive-aggressive: 'Per my last message, I'm still… | On-device | Claude Sonnet |
| 248 | Our team of 6 keeps missing its sprint goals. Give me a structured way to diagno… | Claude Sonnet | On-device |
| 249 | Write a shell command that finds all .log files larger than 100 MB under /var/lo… | Claude Sonnet | On-device |

### Tuning (25 prompts)

| Strategy | Answers passed | Mean score | Cost per 100 prompts | Sent to Claude |
|---|---|---|---|---|
| **HybridRouter** | 96% | 4.44 | $0.66 | 64% |
| Always on-device | 60% | 3.04 | $0.00 | 0% |
| Always Claude Sonnet | 100% | 4.76 | $0.76 | 100% |
| Always Claude Opus | 100% | 4.88 | $1.72 | 100% |
| Always Muse Wonder | 100% | 4.64 | $2.06 | 0% |
| Random, same mix | 86% | 4.14 | $0.48 | 64% |
| Oracle (cheapest good-enough) | 100% | 4.24 | $0.45 | 40% |

Router vs the cheapest good-enough route: 17 matched, 7 over-routed (paid more than needed), 1 under-routed (answer failed where a bigger model passed), 0 no route passed.
It recovers 90% of the quality gap between always-on-device and always-Claude.

| # | Prompt | Router | Cheapest good-enough |
|---|---|---|---|
| 1 | What's the best month to visit Japan for cherry blossoms? | Claude Sonnet | On-device |
| 11 | Is a 50-minute layover in Chicago O'Hare enough to change terminals? | Claude Sonnet | On-device |
| 14 | Write a polite email asking the hotel for early check-in | Claude Sonnet | On-device |
| 35 | Write a haiku about Monday mornings | On-device | Claude Sonnet |
| 36 | Explain the difference between a Roth and a traditional IRA | Claude Sonnet | On-device |
| 40 | Plan a weekly study schedule for learning Spanish in 3 months | Claude Sonnet | On-device |
| 41 | Outline a 5-minute talk on climate adaptation | Claude Sonnet | On-device |
| 44 | Prove that the square root of 2 is irrational | Claude Sonnet | On-device |