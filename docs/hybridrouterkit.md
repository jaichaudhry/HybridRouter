# Using HybridRouterKit in your app

HybridRouterKit is a Swift package with no UI.

## Install

**Requirements:** Xcode 27, an iOS 27 or macOS 27 target, and a device or simulator with Apple Intelligence turned on, for the on-device model and classifier. A cloud model is optional.

**In Xcode:** choose **File › Add Package Dependencies…**, paste `https://github.com/jaichaudhry/HybridRouter`, choose **Up to Next Major Version** from `0.5.0`, and add the **HybridRouterKit** library to your app target.

**In `Package.swift`:**

```swift
dependencies: [
    .package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.5.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "HybridRouterKit", package: "HybridRouter"),
        .product(name: "HybridRouterKitVoice", package: "HybridRouter"),   // optional: voice input
    ]),
    // Optional: fake models for your tests.
    .testTarget(name: "MyAppTests", dependencies: [
        .product(name: "HybridRouterKitTesting", package: "HybridRouter"),
    ]),
]
```

**Keys:** don't put an API key in your source. While developing, read it from the Keychain (`KeychainStore`) or an untracked config. In a shipped app, use App Attest (`.claudeAuth(.appAttest(clientID:))`) so no key ships at all. With `cloud: .off`, everything runs on Apple's models and no key is needed.

## The short version: `HybridAssistant`

```swift
import HybridRouterKit

let assistant = HybridAssistant(
    instructions: "You are a helpful travel assistant.",
    cloud: .claude(apiKey: key)          // or .museWonder(apiKey:), .claudeAuth(.appAttest(clientID:)), .off
    // whenTooLong: .trimHistory          // stay on the picked model in long chats instead of moving up
)

let reply = await assistant.respond(to: "Plan three days in Kyoto")
print(reply.text)                         // the answer
print(reply.decision?.reason ?? "")       // "Multi-step planning"
print(reply.cost)                         // estimated USD for this turn
```

In a SwiftUI view:

```swift
import HybridRouterKit
import SwiftUI

struct AskView: View {
    @State private var assistant = HybridAssistant(instructions: "You are a helpful travel assistant.", cloud: .off)
    @State private var answer = ""
    @State private var route = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(route).font(.caption).foregroundStyle(.secondary)   // e.g. "On-device · Quick conversation"
            Text(answer)
            Button("Ask") {
                Task {
                    for await event in assistant.send("Best month for cherry blossoms in Japan?") {
                        switch event {
                        case .routed(let decision): route = "\(assistant.session.labels.name(decision.route)) · \(decision.reason)"
                        case .partial(let content): answer = content.text
                        case .finished(let reply): answer = reply.text
                        }
                    }
                }
            }
            .disabled(assistant.isResponding)
        }
        .padding()
        .task { await assistant.prewarm() }
    }
}
```

To stream without a view:

```swift
for await event in assistant.send("Compare these two hotels") {
    switch event {
    case .routed(let decision): print("→", decision.route, decision.reason)
    case .partial(let content): print(content.text)        // the reply so far
    case .finished(let reply): print("done:", reply.failure ?? "ok")
    }
}
```

Out of the box it:

- **checks privacy on-device first.** Card numbers, IDs, contact details and health terms, plus messages with an image or sent with `isPrivate: true`, stay on Apple's models. The cloud model only ever sees `[Private message withheld]` in their place. Set `privacyGuard = nil` or `keepsImagesPrivate = false` to change that.
- **routes each message** with the rules, the exact-answer check and the on-device classifier. Pass `route:` to force one.
- **handles failures.** A rate limit, timeout or dropped connection is retried once on the same route after about a second. The turn then escalates one route up, or **falls back** to a smaller model when nothing above can help, for example when Claude stays rate limited or the phone goes offline mid-reply. A route the user forced is retried but never moved.
- **tracks the network** and **keeps the Claude key out of logs.**

`assistant.summary` gives the route mix and cost so far. `assistant.session` is the underlying `RoutedSession`, holding the transcript and the private turn IDs to carry into a rebuilt session.

For a shipped app, use App Attest instead of an embedded key: `cloud: .claudeAuth(.appAttest(clientID: "clid_…"))`. Pass `appleCloudEnabled: true` once your team has the Private Cloud Compute entitlement.

## Voice input

`HybridRouterKitVoice` turns speech into text on the device, with Apple's `SpeechTranscriber`: the audio never leaves the phone. The text then goes through the same privacy check and routing as a typed message.

```swift
import HybridRouterKitVoice

let voice = VoiceInput(for: assistant)   // expects "Claude", "Muse Wonder", "Apple Cloud"…
try await voice.start()                  // voice.text updates as the user speaks
let transcript = await voice.stop()      // final text, usually within 0.1 s of stopping
let reply = await assistant.respond(to: transcript.text)
```

- **Add the library and a permission string.** Add the `HybridRouterKitVoice` product to your target and `NSMicrophoneUsageDescription` to your Info.plist. Voice is a separate library so apps that don't use it never reference microphone APIs, which App Store review checks for.
- **Live text.** `finalText` holds words that won't change; `volatileText` is the latest guess (show it dimmed); `text` is both. `level` (0–1) drives a level meter.
- **Names.** `VoiceInput(for:)` passes the assistant's model names to the speech model as hints, so "ask Claude" isn't heard as "ask cloud" and still routes as asked. Add your own with `vocabulary:`.
- **Recordings.** `VoiceInput.transcribe(audioFile:)` transcribes a file. `recordingURL` saves live audio, e.g. to compare `.speech` with `.dictation` (the keyboard dictation model) on the same recording.
- **The speech model** is downloaded once per language if it isn't on the device yet; the first `start()` can take a moment.

On an iPhone, 20 prompts read aloud had 3 real word errors in 154 (1.9%), and every privacy decision matched the typed prompt. The one error that mattered, "r's" heard as "hours", is caught by the exact-answer rule ([results](../Evals/results/2026-10-19-iphone-speech-check.md)).

## Full control: `RoutedSession` and `TurnCoordinator`

`HybridAssistant` is a thin layer over these. Use them directly to supply your own providers, classifier, mapping, escalation policy or token estimator:

```swift
let network = NetworkMonitor()
let session = RoutedSession(
    instructions: "You are a helpful travel assistant.",
    onDevice: OnDeviceProvider(),
    appleCloud: AppleCloudProvider(isEnabled: false),
    cloud: ClaudeProvider(auth: .apiKey(key)),          // or MuseProvider(apiKey:), or your own ModelProvider
    costTable: try CostTable.bundled(),
    historyPolicy: .full
)
let coordinator = TurnCoordinator(
    router: Router(classifier: OnDeviceClassifier(), detectsExactAnswers: true),
    policy: EscalationPolicy(transientRetries: 1, retryDelay: .seconds(1), fallsBack: true),
    estimator: OnDeviceTokenEstimator(),
    isOnline: { network.isOnline }
)

let privacy = PrivacyGuard().assess(prompt)
let outcome = await coordinator.run(.init(prompt: prompt, privacyReason: privacy?.label), in: session)
```

With this API, the privacy check is up to you: a turn is only private if you pass `privacyReason`.

### Your own cloud model

Any `LanguageModel` can serve the cloud route. Conform a type to `ModelProvider` with `route: .cloud` and give it a `displayName`; reasons and badges then use that name ("You asked for Gemini"). Add its price to a `CostTable` so its cost is counted. Steps from a model without a price are reported in `SessionSummary.unpricedSteps` rather than silently counted as free.

### How much history each route sees

`HistoryPolicy` limits how much of the earlier conversation a route sees. The transcript itself is never trimmed:

```swift
historyPolicy: .recentTokens(2_000)                 // on-device sees the recent turns that fit in ~2,000 tokens
historyPolicy: .recentTurns(6)                      // or a fixed number of turns
historyPolicy: HistoryPolicy(limits: [.onDevice: .tokens(2_000), .appleCloud: .tokens(20_000)])
```

Without a limit, a long conversation (or one pasted document) soon outgrows the on-device model's 4K-token window, and every later turn, even "thanks", has to leave the phone. With one, the on-device model sees only recent turns, so short turns can stay on the phone. The cost is that it can't see older turns. The context-fit rule checks each route against the history it will actually see.

A token limit usually works better than a turn count. On the benchmark, an exchange is about 115 tokens when the phone answers and about 300 when Claude does, and long answers run past 1,000. A fixed turn count either forgets too much or doesn't fit.

On-device has room for about 2,500 tokens of history, after the instructions, the new message and the reply. So `.recentTokens(2_000)` leaves headroom for longer instructions and tools.

Any route can have a limit, but it pays off mostly on-device:

| Route | Window | Limit it? |
|---|---|---|
| On-device | 4K | Yes: it fills after about 6–20 exchanges. |
| Apple Cloud | 32K | Only for very long chats or big pasted documents, e.g. `.tokens(20_000)`. |
| Cloud model | 1M | Usually not. Claude reads a cached prompt at a tenth of the price, and a sliding limit changes the start of the prompt almost every turn, so it pays full price again. A limit of W tokens only saves money once the chat is about 10 × W long. |

It's off by default. The benchmark is mostly single-turn, so it can't yet show what the limit costs in answer quality.

### When a chat is too long for a route

Separately from `HistoryPolicy`, the router handles a chat that has outgrown a route on each turn:

| Situation | What happens |
|---|---|
| Auto, a larger model fits the whole chat | Moves up (default). `decision.tooLongFor` names the route it skipped. |
| Auto, with `Router(whenTooLong: .trimHistory)` | Stays on its pick and answers from the most recent turns that fit. |
| A route the user forced (`route:` / `override`) | Always stays, and answers from the most recent turns that fit. |
| No available model fits the whole chat | Answers from the most recent turns on the best route, instead of failing. |
| The new message alone is too big for the forced route | Blocked: "This message is too long for On-device on its own." |

When a reply saw only part of the chat, `decision.historyBudget` is set, and its `StepMetrics` say how many earlier turns it saw (`earlierTurnsSeen` of `earlierTurns`). `HybridAssistant.Reply.earlierTurnsSeen` gives the same. Show it: the model can't answer about turns it didn't see. Private turns never reach the cloud model in any of these cases.

## Upgrading from 0.3

| 0.3 | 0.4 |
|---|---|
| `Route.claude` | `Route.cloud`. The raw value is still `"claude"`, so saved results and transcripts decode. |
| `RoutedSession(…, claude:)` | `RoutedSession(…, cloud:)`. The old label still works, with a deprecation warning. |
| `SessionSummary(…, claudeModelID:)`, `.allClaudeCost` | `cloudModelID:`, `.allCloudCost`, both deprecated aliases. |
| `EscalationOutcome.retry(decision)` | `.retry(decision, delay:)` |
| `RouteLabels(cloud: CloudModel)` | Still works; `RouteLabels(cloud: provider)` also names unknown providers. |
| `Route.cloud.displayName` was "Claude" | Now "Cloud model". Use `session.labels.name(.cloud)` for the serving model's name. |

Also changed:
- A provider passed for the wrong route now makes that route unavailable with a reason, instead of crashing.
- When only one route can take a turn, the router skips the classifier, saving about 0.6 s per turn.
- A chat too long for a forced route is answered from its recent turns instead of failing, and so is one too long for every available route (including long private chats without Apple Cloud). Moving up for length is unchanged in Auto, and is now marked with `RouteDecision.tooLongFor`. The reason reads "chat too long for On-device".
- The context estimate now counts the instructions, route note, tool descriptions and attached images.

## Testing

`HybridRouterKitTesting` adds fake models, a fake classifier and fixed token estimates, so routing, failure handling and privacy rules can be unit-tested on a Mac without a device or network. `FakeBehavior` includes `.rateLimitedFirst(n)`, `.offline` and `.dropsMidReply` for testing retries and fallback. HybridRouterKit is pre-1.0: its API may change, and it depends on Anthropic's beta `ClaudeForFoundationModels`.

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
