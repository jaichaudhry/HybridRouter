# Using HybridRouterKit in your app

HybridRouterKit is a Swift package (iOS 27, macOS 27) with no UI. Add this repository as a package dependency and pick the `HybridRouterKit` library:

```swift
.package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.2.1")
```

```swift
import HybridRouterKit

/// One conversation that routes each turn between the on-device model, Apple Cloud and Claude.
@MainActor
final class Assistant {
    let session: RoutedSession
    let coordinator: TurnCoordinator
    private let network = NetworkMonitor()

    init(claudeAPIKey: String?) throws {
        let claudeAuth = ClaudeAuthSource.resolve(
            environment: ClaudeAuthEnvironment(
                clientID: nil,                // or your Claude Console client ID for App Attest
                isPhysicalDevice: true,
                isAppAttestSupported: false,
                developerKey: nil,
                allowsDeveloperKey: false
            ),
            userKey: claudeAPIKey
        )
        session = RoutedSession(
            instructions: "You are a helpful travel assistant.",
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: false), // true once your team has the PCC entitlement
            claude: ClaudeProvider(auth: claudeAuth),
            costTable: try CostTable.bundled()
        )
        let network = network
        coordinator = TurnCoordinator(
            router: Router(classifier: OnDeviceClassifier(), detectsExactAnswers: true),
            estimator: OnDeviceTokenEstimator(),
            isOnline: { network.isOnline }
        )
    }

    /// Checks privacy on-device, routes the turn, streams the reply, and escalates on failure.
    func send(_ prompt: String) async -> String {
        let privacy = PrivacyGuard().assess(prompt)
        let outcome = await coordinator.run(
            .init(prompt: prompt, privacyReason: privacy?.label),
            in: session
        ) { event in
            if case .partial(let content) = event {
                print(content.text) // the reply so far
            }
        }
        if let decision = outcome.decision, let metrics = outcome.steps.last {
            print("\(decision.route.displayName): \(decision.reason), \(metrics.estimatedCost ?? 0) USD")
        }
        return outcome.content?.text ?? outcome.failure ?? ""
    }
}
```

`HybridRouterKitTesting` adds fake models and a fake classifier, so your routing and privacy rules can be unit-tested on a Mac without a device or network. HybridRouterKit is pre-1.0: its API may change, and it depends on Anthropic's beta `ClaudeForFoundationModels`.

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
