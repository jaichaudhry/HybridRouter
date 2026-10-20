import Foundation
import FoundationModels
import Observation

/// One routed conversation, set up with sensible defaults: the simplest way to use HybridRouterKit.
///
/// ```swift
/// let assistant = HybridAssistant(
///     instructions: "You are a helpful travel assistant.",
///     cloud: .claude(apiKey: key)
/// )
/// let reply = await assistant.respond(to: "Plan three days in Kyoto")
/// print(reply.text, reply.decision?.reason ?? "")
/// ```
///
/// Each message is checked for private details on-device first (``PrivacyGuard``); a private
/// message, and anything derived from it, never reaches the cloud model. The router then picks
/// a route, and failures are retried, escalated or fall back to a smaller model.
///
/// For full control, build a ``RoutedSession`` and ``TurnCoordinator`` yourself.
@MainActor
@Observable
public final class HybridAssistant {
    /// The model behind the cloud route.
    public enum Cloud: Sendable {
        /// No cloud model: turns stay on Apple's models.
        case off
        /// Claude with an Anthropic API key. Ship with ``claudeAuth(_:tier:)`` and App Attest instead.
        case claude(apiKey: String, tier: ClaudeProvider.Tier = .standard)
        /// Claude with resolved credentials, e.g. `.appAttest(clientID:)` for a shipped app.
        case claudeAuth(ClaudeAuth, tier: ClaudeProvider.Tier = .standard)
        /// Meta's Muse Wonder with a Meta Model API key.
        case museWonder(apiKey: String)
        /// Any provider for the cloud route.
        case provider(any ModelProvider)

        var provider: any ModelProvider {
            switch self {
            case .off: ClaudeProvider(auth: .off)
            case .claude(apiKey: let apiKey, tier: let tier): ClaudeProvider(auth: .apiKey(apiKey), tier: tier)
            case .claudeAuth(let auth, let tier): ClaudeProvider(auth: auth, tier: tier)
            case .museWonder(let apiKey): MuseProvider(apiKey: apiKey)
            case .provider(let provider): provider
            }
        }
    }

    /// One reply, or why there isn't one.
    public struct Reply: Sendable {
        /// The reply, if any route answered.
        public var content: TurnContent?
        /// The route that answered (or last tried) and why.
        public var decision: RouteDecision?
        /// Why the message was kept off the cloud model, if it was.
        public var privacyReason: String?
        /// Every step that ran, including failed attempts, with latency, tokens and cost.
        public var steps: [StepMetrics]
        /// Shown to the user when the turn couldn't be answered, or the reply was cut off.
        public var failure: String?

        /// When the chat was too long for the route and it answered from recent turns: how many
        /// earlier turns it saw, out of how many.
        public var earlierTurnsSeen: (seen: Int, total: Int)? {
            guard let step = steps.last, step.leftOutEarlierTurns,
                  let seen = step.earlierTurnsSeen, let total = step.earlierTurns else { return nil }
            return (seen, total)
        }

        /// The reply as text, or the failure if there's no reply.
        public var text: String { content?.text ?? failure ?? "" }
        /// Estimated cost of the turn in US dollars, failed attempts included.
        public var cost: Double { steps.reduce(0) { $0 + ($1.estimatedCost ?? 0) } }
    }

    /// What ``send(_:images:isPrivate:route:)`` reports as a turn runs.
    public enum Event: Sendable {
        /// A route was chosen, or the turn moved to another one.
        case routed(RouteDecision)
        /// The reply so far.
        case partial(TurnContent)
        /// The turn finished.
        case finished(Reply)
    }

    /// The conversation. Read its transcript, or pass ``RoutedSession/privatePromptIDs`` on
    /// when you rebuild it.
    public let session: RoutedSession
    /// Runs each turn. Its router, policy and estimator can be changed between turns.
    public var coordinator: TurnCoordinator
    /// Checks each message on-device. Nil turns the automatic check off: then only messages
    /// sent with `isPrivate: true` are kept private.
    public var privacyGuard: PrivacyGuard?
    /// Messages with an image stay off the cloud model, since a photo can show anything.
    public var keepsImagesPrivate: Bool
    /// Every step of every turn so far.
    public private(set) var steps: [StepMetrics] = []
    /// The restored conversation's private turns didn't line up with its transcript, so every
    /// earlier turn is kept from the cloud model. See ``RestoredConversation/isConservative``.
    public let restoredConservatively: Bool
    /// True while a reply is being generated.
    public var isResponding: Bool { session.isResponding }

    private let costTable: CostTable

    /// - Parameters:
    ///   - instructions: the system instructions, shared by every route.
    ///   - cloud: the cloud model, if any.
    ///   - appleCloudEnabled: true once your team has the Private Cloud Compute entitlement.
    ///   - tools: tools every route may call.
    ///   - historyPolicy: how much of the conversation each route sees.
    ///   - whenTooLong: when the chat is too long for the route the router picks, move to a
    ///     larger model (the default) or stay and answer from the recent turns. A route passed
    ///     with `route:` always stays.
    ///   - restoring: a conversation saved with ``snapshot()``, to continue it.
    public convenience init(
        instructions: String,
        cloud: Cloud = .off,
        appleCloudEnabled: Bool = false,
        tools: [any Tool] = [],
        historyPolicy: HistoryPolicy = .full,
        whenTooLong: Router.TooLongPolicy = .useLargerModel,
        restoring: RestoredConversation? = nil
    ) {
        let network = NetworkMonitor()
        self.init(
            instructions: instructions,
            tools: tools,
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: appleCloudEnabled),
            cloud: cloud.provider,
            router: Router(classifier: OnDeviceClassifier(), detectsExactAnswers: true, whenTooLong: whenTooLong),
            estimator: OnDeviceTokenEstimator(),
            historyPolicy: historyPolicy,
            restoring: restoring,
            isOnline: { network.isOnline }
        )
    }

    /// Every part injected, e.g. fakes from `HybridRouterKitTesting` in tests.
    public init(
        instructions: String,
        tools: [any Tool] = [],
        onDevice: any ModelProvider,
        appleCloud: any ModelProvider,
        cloud: any ModelProvider,
        router: Router,
        policy: EscalationPolicy = EscalationPolicy(),
        estimator: any TokenEstimator,
        costTable: CostTable? = nil,
        privacyGuard: PrivacyGuard? = PrivacyGuard(),
        keepsImagesPrivate: Bool = true,
        history: [Transcript.Entry] = [],
        privatePromptIDs: Set<String> = [],
        historyPolicy: HistoryPolicy = .full,
        restoring: RestoredConversation? = nil,
        isOnline: @escaping @Sendable () -> Bool
    ) {
        let costTable = costTable ?? (try? CostTable.bundled()) ?? CostTable(updated: "", source: "", models: [:])
        self.costTable = costTable
        self.session = RoutedSession(
            instructions: instructions,
            tools: tools,
            onDevice: onDevice,
            appleCloud: appleCloud,
            cloud: cloud,
            costTable: costTable,
            history: restoring?.history ?? history,
            privatePromptIDs: restoring?.privatePromptIDs ?? privatePromptIDs,
            historyPolicy: historyPolicy,
            lastRoute: restoring?.lastRoute
        )
        self.restoredConservatively = restoring?.isConservative ?? false
        self.coordinator = TurnCoordinator(router: router, policy: policy, estimator: estimator, isOnline: isOnline)
        self.privacyGuard = privacyGuard
        self.keepsImagesPrivate = keepsImagesPrivate
    }

    /// Loads the classifier and on-device model so the first reply starts sooner. Call it when
    /// the conversation's screen appears.
    public func prewarm() async {
        session.prewarm(.onDevice)
        await coordinator.prewarm()
    }

    /// Sends a message and waits for the whole reply.
    /// - Parameters:
    ///   - isPrivate: keep this message off the cloud model whatever it says.
    ///   - route: run on this route instead of letting the router pick.
    public func respond(
        to prompt: String,
        images: [ImageInput] = [],
        isPrivate: Bool = false,
        route: Route? = nil
    ) async -> Reply {
        await run(prompt, images: images, isPrivate: isPrivate, route: route) { _ in }
    }

    /// Sends a message and streams the route, the reply as it grows, and the finished reply.
    /// Cancelling the iteration cancels the turn.
    public func send(
        _ prompt: String,
        images: [ImageInput] = [],
        isPrivate: Bool = false,
        route: Route? = nil
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let reply = await run(prompt, images: images, isPrivate: isPrivate, route: route) { event in
                    switch event {
                    case .routed(let decision): continuation.yield(.routed(decision))
                    case .partial(let content): continuation.yield(.partial(content))
                    }
                }
                continuation.yield(.finished(reply))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why a message would be kept private, or nil if it may reach the cloud model.
    public func privacyReason(for prompt: String, images: [ImageInput] = [], isPrivate: Bool = false) -> String? {
        if let reason = privacyGuard?.assess(prompt, markedPrivate: isPrivate) {
            return reason.label
        }
        if isPrivate { return PrivacyGuard.Reason.markedPrivate.label }
        if keepsImagesPrivate, !images.isEmpty { return "attached image" }
        return nil
    }

    /// The conversation so far, to save (it's `Codable`) and continue later with `restoring:`.
    /// It holds everything said, private turns included: store it with file protection.
    public func snapshot() -> ConversationSnapshot {
        session.snapshot()
    }

    /// Route mix and cost so far, and what the same turns would have cost on the cloud model.
    public var summary: SessionSummary {
        SessionSummary(steps: steps, costTable: costTable, cloudModelID: session.provider(for: .cloud).modelID)
    }

    private func run(
        _ prompt: String,
        images: [ImageInput],
        isPrivate: Bool,
        route: Route?,
        onEvent: (TurnCoordinator.Event) -> Void
    ) async -> Reply {
        let privacyReason = privacyReason(for: prompt, images: images, isPrivate: isPrivate)
        let outcome = await coordinator.run(
            .init(prompt: prompt, images: images, override: route, privacyReason: privacyReason),
            in: session,
            onEvent: onEvent
        )
        steps += outcome.steps
        return Reply(
            content: outcome.content,
            decision: outcome.decision,
            privacyReason: privacyReason,
            steps: outcome.steps,
            failure: outcome.failure
        )
    }
}
