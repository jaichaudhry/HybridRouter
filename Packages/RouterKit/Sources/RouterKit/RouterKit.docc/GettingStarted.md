# Getting started

Add RouterKit to an app and route a conversation.

## Add the package

RouterKit needs iOS 27 or macOS 27. In Xcode, add the package `https://github.com/jaichaudhry/HybridRouter` and the `RouterKit` library, or in `Package.swift`:

```swift
.package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.1.0")
```

## Route a conversation

Create a RoutedSession with one provider per route, and a TurnCoordinator to run each turn:

```swift
import RouterKit

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
            router: Router(classifier: OnDeviceClassifier()),
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

Without a Claude key the Claude route reports itself unavailable and the router never picks it. Apple Cloud needs Apple's Private Cloud Compute entitlement; until your team has it, pass `isEnabled: false` (or use SimulatedAppleCloudProvider while developing).

## Test without a device

The `RouterKitTesting` library has fake models and a fake classifier that run through Apple's real `LanguageModelSession`, so routing, escalation and privacy can be tested with `swift test` on a Mac.
