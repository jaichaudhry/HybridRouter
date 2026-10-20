# How it works

HybridRouter keeps one conversation and picks a model for every turn. This page covers the architecture, the routing steps, the privacy guarantees and the Apple APIs behind them. For a guided tour of the app, see [the tour](#the-app) below.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/architecture-dark.svg">
  <img src="images/architecture-light.svg" width="100%" alt="Architecture: the app's scenarios use ChatUI, which runs each turn through HybridRouterKit. HybridRouterKit checks privacy, applies rules, asks the on-device classifier and escalates on failure, over one shared LanguageModelSession that switches between the on-device model, Apple Private Cloud Compute and the cloud model.">
</picture>

## How routing works

For each turn:

1. **PrivacyGuard** checks the message on-device: the Private toggle, scanned documents, card numbers (Luhn-checked), ID numbers, phone numbers, emails, addresses and health terms.
2. **Hard rules** settle the obvious cases, in order: your route override, privacy (never Claude), offline (on-device only), context fit (see below), images (a model that can see them), a model you name in the message ("ask Claude"), bare follow-ups like "Why?" (stay with the model that answered), and questions with one exact answer, such as counting letters, arithmetic, date maths or unit conversions (go to the cloud model, which gets them right far more often). Each model is also told it shares the conversation with the other two, so it doesn't deny that Claude exists when you ask for it.
3. **The on-device classifier** labels everything else as simple, moderate or complex, which maps to on-device, Apple Cloud or Claude. Each scenario can change the mapping, and each on-device model variant gets its own tuned instructions.
4. **Long chats.** Every request carries the whole conversation, and the on-device model's window is 4K tokens. When a chat outgrows the route the router picks, Auto moves it to the next model that can see the whole chat, and the reply says so ("This chat is too long for On-device, so Claude answered with the whole conversation"). In Settings › Long chats, Auto can instead stay on its pick and answer from the most recent messages. A model you pick in the composer always stays: it answers from the most recent messages that fit, and the reply says how many it saw ("saw only the last 3 of 8 earlier exchanges"). The same happens when no available model fits the whole chat, for example a long private chat without Apple Cloud, which used to fail with "Too long to keep private".
5. **Failures.** A rate limit, timeout or dropped connection on Apple Cloud or the cloud model is retried once on the same route after about a second. After that, or for any other failure (context too long, decode failure, an empty reply), the turn escalates one route up. If nothing above can help, for example when the cloud model stays rate limited or the phone goes offline mid-reply, it falls back to a smaller model. A turn never revisits a route it has already tried. A route the user forced is retried but never moved, and a private turn never reaches the cloud model.

Each badge says why its reply went where it did ("Multi-step planning", "Kept private: scanned document", "Escalated: timed out", "Fell back: rate limited").

## Privacy and security

- **Saved chats stay private.** Chats are saved only on the iPhone, with complete file protection (unreadable while it's locked) and left out of backups. A reopened chat keeps withholding its private turns from the cloud model; if the saved record of them doesn't match the conversation, the cloud model sees none of its earlier messages.
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
- **Dictation:** with the field empty, the mic button turns speech into text on the device. Words appear as you speak, with bars that follow your voice; tap them to stop, check the text, then send. It's routed and privacy-checked like typing.
- **Chats are saved** once they have a message. The app opens to a new chat; the clock button lists saved ones by scenario, and the pencil starts a new one. Swipe to delete. Settings can turn saving off or delete them all.
- **Compare mode** (the ⋯ menu) runs one prompt on all three routes side by side, with each route's speed and cost.
- **Settings › Developer** has the tools that produced the [results](results.md): a routing benchmark, per-route measurements, the speech check, Apple Cloud checks, and (in Debug builds) a simulated Apple Cloud for developing without Apple's entitlement.

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
| `SpeechAnalyzer`, `SpeechTranscriber`, `AnalysisContext`, `AVAudioEngine.installAudioTap` | On-device dictation with model names as hints; the speech check | `HybridRouterKitVoice/VoiceInput.swift`, `App/Settings/SpeechCheckView.swift` |
| `ClaudeLanguageModel`, `ClaudeModel`, `AuthMode`, App Attest | Claude route; API key or App Attest auth | `HybridRouterKit/Providers/ClaudeProvider.swift`, `Auth/` |
| `NSDataDetector`, regular expressions | On-device PII detection | `HybridRouterKit/Privacy/PrivacyGuard.swift` |
| VisionKit, PDFKit, PhotosUI | Document scanner, PDF import, photo picker | `ChatUI/DocumentScanner.swift`, `ChatAttachment.swift`, `Composer.swift` |
| Keychain, DeviceCheck, Network | Key storage, App Attest support check, offline detection | `Auth/KeychainStore.swift`, `App/AppConfig.swift`, `Routing/NetworkMonitor.swift` |
| Observation, `Synchronization.Mutex`, Swift Testing | Swift 6 concurrency without locks; tests | throughout |

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
