# ``RouterKit``

Route each turn of a conversation to Apple's on-device model, Apple's Private Cloud Compute, or Claude, in one shared conversation.

## Overview

All three models implement Foundation Models' `LanguageModel` protocol, so a ``RoutedSession`` keeps one `LanguageModelSession` and one transcript while the model changes per turn. A ``TurnCoordinator`` runs each turn: ``RoutingRules`` settle the obvious cases (privacy, offline, context size, images), the ``OnDeviceClassifier`` labels the rest, and an ``EscalationPolicy`` retries failures one route up. ``PrivacyGuard`` flags sensitive turns on-device, and Claude only ever sees placeholders for them.

Every step reports ``StepMetrics``: route, reason, latency, tokens and estimated cost.

## Topics

### Essentials

- <doc:GettingStarted>
- ``RoutedSession``
- ``TurnCoordinator``

### Routing

- ``Router``
- ``RoutingRules``
- ``RoutingInput``
- ``RouteDecision``
- ``Route``
- ``OnDeviceClassifier``
- ``RouteClassification``
- ``ComplexityMapping``
- ``EscalationPolicy``
- ``FailureCause``

### Models

- ``ModelProvider``
- ``OnDeviceProvider``
- ``AppleCloudProvider``
- ``SimulatedAppleCloudProvider``
- ``ClaudeProvider``

### Privacy and credentials

- ``PrivacyGuard``
- ``ClaudeAuthSource``
- ``ClaudeAuth``
- ``KeychainStore``

### Measuring

- ``StepMetrics``
- ``CostTable``
- ``SessionSummary``
- ``RoutingBenchmark``
