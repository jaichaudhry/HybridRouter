# Getting started

Add HybridRouterKit to an app and route a conversation.

## Add the package

HybridRouterKit needs iOS 27 or macOS 27. In Xcode, add the package `https://github.com/jaichaudhry/HybridRouter` and the `HybridRouterKit` library, or in `Package.swift`:

```swift
.package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.5.0")
```

## Route a conversation

``HybridAssistant`` sets everything up with defaults: an on-device privacy check, the router with its exact-answer rule, retries and fallback, and network tracking.

```swift
import HybridRouterKit

let assistant = HybridAssistant(
    instructions: "You are a helpful travel assistant.",
    cloud: .claude(apiKey: key)   // .museWonder(apiKey:), .claudeAuth(.appAttest(clientID:)) or .off
)

let reply = await assistant.respond(to: "Plan three days in Kyoto")
print(reply.decision?.reason ?? "", reply.text, reply.cost)

for await event in assistant.send("Compare these two hotels") {
    if case .partial(let content) = event { print(content.text) }   // the reply so far
}
```

Without a cloud model, every turn stays on Apple's models. Apple Cloud needs Apple's Private Cloud Compute entitlement: pass `appleCloudEnabled: true` once your team has it.

## Full control

For your own providers, classifier, ``ComplexityMapping``, ``EscalationPolicy`` or ``HistoryPolicy``, build a ``RoutedSession`` and a ``TurnCoordinator``:

```swift
let network = NetworkMonitor()
let session = RoutedSession(
    instructions: "You are a helpful travel assistant.",
    onDevice: OnDeviceProvider(),
    appleCloud: AppleCloudProvider(isEnabled: false),
    cloud: ClaudeProvider(auth: .apiKey(key)),
    costTable: try CostTable.bundled()
)
let coordinator = TurnCoordinator(
    router: Router(classifier: OnDeviceClassifier(), detectsExactAnswers: true),
    estimator: OnDeviceTokenEstimator(),
    isOnline: { network.isOnline }
)
let privacy = PrivacyGuard().assess(prompt)
let outcome = await coordinator.run(.init(prompt: prompt, privacyReason: privacy?.label), in: session)
```

Here the privacy check is up to you: a turn is only kept off the cloud model if you pass `privacyReason`.

## Test without a device

The `HybridRouterKitTesting` library has fake models and a fake classifier that run through Apple's real `LanguageModelSession`, so routing, escalation, fallback and privacy can be tested with `swift test` on a Mac.
