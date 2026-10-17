# ``HybridRouterKit``

Route each turn of a conversation to Apple's on-device model, Apple's Private Cloud Compute, or a cloud model such as Claude, in one shared conversation.

## Overview

``HybridAssistant`` is the quickest start. Underneath, all three models implement Foundation Models' `LanguageModel` protocol, so a ``RoutedSession`` keeps one `LanguageModelSession` and one transcript while the model changes per turn. A ``TurnCoordinator`` runs each turn: ``RoutingRules`` settle the obvious cases (privacy, offline, context size, images, exact answers), the ``OnDeviceClassifier`` labels the rest, and an ``EscalationPolicy`` retries, escalates or falls back when a step fails. ``PrivacyGuard`` flags sensitive turns on-device, and the cloud model only ever sees placeholders for them.

Every step reports ``StepMetrics``: route, reason, latency, tokens and estimated cost.

## Topics

### Essentials

- <doc:GettingStarted>
- ``HybridAssistant``
- ``RoutedSession``
- ``TurnCoordinator``
- ``HistoryPolicy``
- ``TurnContent``
- ``ImageInput``
- ``StructuredOutput``

### Routing

- ``Router``
- ``RoutingRules``
- ``RoutingInput``
- ``RouteDecision``
- ``Route``
- ``OnDeviceClassifier``
- ``RouteClassification``
- ``ComplexityMapping``
- ``ExactAnswerDetector``
- ``NeedsClassifier``
- ``RouteLabels``
- ``EscalationPolicy``
- ``FailureCause``
- ``TokenEstimator``
- ``NetworkMonitor``

### Models

- ``ModelProvider``
- ``OnDeviceProvider``
- ``AppleCloudProvider``
- ``SimulatedAppleCloudProvider``
- ``ClaudeProvider``
- ``MuseProvider``
- ``CloudModel``

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
