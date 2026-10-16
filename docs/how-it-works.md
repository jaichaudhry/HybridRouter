# How it works

HybridRouter keeps one conversation and picks a model for every turn. This page covers the architecture, the routing steps, the privacy guarantees and the Apple APIs behind them. For a guided tour of the app, see [the tour](#the-app) below.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/architecture-dark.svg">
  <img src="images/architecture-light.svg" width="100%" alt="Architecture: the app's scenarios use ChatUI, which runs each turn through HybridRouterKit. HybridRouterKit checks privacy, applies rules, asks the on-device classifier and escalates on failure, over one shared LanguageModelSession that switches between the on-device model, Apple Private Cloud Compute and the cloud model.">
</picture>

## How routing works

For each turn:

1. **PrivacyGuard** checks the message on-device: the Private toggle, scanned documents, card numbers (Luhn-checked), ID numbers, phone numbers, emails, addresses and health terms.
2. **Hard rules** settle the obvious cases, in order: your route override, privacy (never Claude), offline (on-device only), context fit (only models big enough for the conversation), images (a model that can see them), a model you name in the message ("ask Claude"), bare follow-ups like "Why?" (stay with the model that answered), and questions with one exact answer, such as counting letters, arithmetic, date maths or unit conversions (go to the cloud model, which gets them right far more often). Each model is also told it shares the conversation with the other two, so it doesn't deny that Claude exists when you ask for it.
3. **The on-device classifier** labels everything else as simple, moderate or complex, which maps to on-device, Apple Cloud or Claude. Each scenario can change the mapping, and each on-device model variant gets its own tuned instructions.
4. **Escalation** retries a failed reply one route up: context too long, timeout, rate limit, decode failure, or an empty or cut-off reply. A private turn never escalates to Claude.

Each badge says why its reply went where it did ("Multi-step planning", "Kept private: scanned document", "Escalated: timed out").

## Privacy and security

- **Private turns stay with Apple.** Once a conversation has a private turn, Claude sees it, and every later turn answered by Apple's models, as "[Private message withheld]". This holds across escalation, follow-ups and session rebuilds, and is covered by tests that check the request Claude actually receives.
- **Scans are private by default.** OCR and barcode tools run only on Apple routes. Images that do go to Claude (non-private photos) are re-encoded without EXIF or GPS data.
- **No keys in the repo or the binary.** A key you paste is stored in the device's Keychain. Developer keys come only from a gitignored `Secrets.xcconfig` and are blanked in Release builds. Shipped builds use App Attest instead of a key. Keys never appear in logs, metrics or exports.
- **Secret scanning:** gitleaks runs in a pre-commit hook and in CI.

## The app

The app has three scenarios, picked from the title bar. It opens in Chat, then reopens wherever you were last. Sample prompts appear as chips above the composer.

| Scenario | Try | Where it goes |
|---|---|---|
| **Chat** | "Give me three dinner ideas" | On-device |
| | "Explain how vaccines work in two paragraphs" | Apple Cloud (Claude when Apple Cloud isn't available) |
| | "Which is better for a beginner, Swift or Kotlin, and why?" | Claude |
| **Trip Planner** | "Give me 5 weekend trip ideas from Seattle" | On-device (or Apple Cloud on newer iPhones) |
| | "Make a 3-day Kyoto itinerary for a family with two kids" | Apple Cloud, rendered as day cards |
| | "Is this plan realistic with jet lag and a 4-year-old? What would you cut?" | Claude |
| | "Rewrite day 2 as a short text to my partner" | On-device |
| **Document Helper** | Scan a receipt, then "Extract the total and merchant" | On-device, kept private, rendered as a receipt card |
| | Import a contract, then "Summarize the key risks" | Claude, or Apple Cloud if it's private |

- **The composer** has a "+" menu for attachments (photos, the document scanner, text or PDF files) and the route (Auto, On-device, Apple Cloud, Claude), and a Private lock in the message field.
- **Compare mode** (toolbar) runs one prompt on all three routes side by side, with each route's speed and cost.
- **Settings › Developer** has the tools that produced the [results](results.md): a routing benchmark, per-route measurements, Apple Cloud checks, and (in Debug builds) a simulated Apple Cloud for developing without Apple's entitlement.

## APIs and frameworks used

| API | What it does here | Where |
|---|---|---|
| `LanguageModel`, `LanguageModelSession` | One session and transcript shared by all three models | `HybridRouterKit/Session/RoutedSession.swift` |
| Dynamic Profiles (`DynamicProfile`, `@SessionProperty`, `.model`, `.historyTransform`) | Switch the model per turn; withhold private turns from Claude | `HybridRouterKit/Session/RoutingProfile.swift` |
| `SystemLanguageModel` (`availability`, `contextSize`, `tokenCount(for:)`, `variant`) | On-device route, token estimates for context fit, per-variant tuning | `HybridRouterKit/Providers/OnDeviceProvider.swift`, `Routing/TokenEstimator.swift` |
| `PrivateCloudComputeLanguageModel` (`availability`, `quotaUsage`, `contextSize`) | Apple Cloud route, quota-aware | `HybridRouterKit/Providers/AppleCloudProvider.swift` |
| `@Generable`, `@Guide`, streaming partial results | The routing classifier; itinerary, receipt and summary cards that fill in while streaming | `Routing/RouteClassification.swift`, `App/Scenarios/` |
| `Tool` | Trip Planner's `findPlaces` | `App/Scenarios/TripPlanner/PlacesTool.swift` |
| `Attachment` (images), `OCRTool`, `BarcodeReaderTool` | Reading scanned receipts and notes on Apple routes only | `RoutedSession.swift`, `App/Scenarios/DocumentHelper/` |
| `LanguageModelSession.Usage`, `LanguageModelError` | Per-step tokens and cost; failure causes for escalation | `Telemetry/`, `Routing/EscalationPolicy.swift` |
| Evaluations framework | The classifier benchmark as an Apple evaluation | `Evals/AppleEvaluationTests.swift` |
| `ClaudeLanguageModel`, `ClaudeModel`, `AuthMode`, App Attest | Claude route; API key or App Attest auth | `HybridRouterKit/Providers/ClaudeProvider.swift`, `Auth/` |
| `NSDataDetector`, regular expressions | On-device PII detection | `HybridRouterKit/Privacy/PrivacyGuard.swift` |
| VisionKit, PDFKit, PhotosUI | Document scanner, PDF import, photo picker | `ChatUI/DocumentScanner.swift`, `ChatAttachment.swift`, `Composer.swift` |
| Keychain, DeviceCheck, Network | Key storage, App Attest support check, offline detection | `Auth/KeychainStore.swift`, `App/AppConfig.swift`, `Routing/NetworkMonitor.swift` |
| Observation, `Synchronization.Mutex`, Swift Testing | Swift 6 concurrency without locks; tests | throughout |

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
