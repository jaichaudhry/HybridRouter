import Foundation
import FoundationModels
import Observation

/// A conversation whose turns can each run on a different route, sharing one transcript.
///
/// Turns are serialized: a `LanguageModelSession` rejects overlapping requests, and the
/// active route must not change while a response is streaming.
@MainActor
@Observable
public final class RoutedSession {
    public enum Error: Swift.Error, Equatable {
        case routeUnavailable(Route, reason: String)
        case busy
    }

    public struct TurnResult: Sendable {
        public let text: String
        public let metrics: StepMetrics
    }

    public private(set) var isResponding = false

    @ObservationIgnored private let session: LanguageModelSession
    @ObservationIgnored private let providers: [Route: any ModelProvider]
    @ObservationIgnored private let costTable: CostTable

    public init(
        instructions: String,
        onDevice: any ModelProvider,
        appleCloud: any ModelProvider,
        claude: any ModelProvider,
        costTable: CostTable,
        history: [Transcript.Entry] = []
    ) {
        precondition(onDevice.route == .onDevice && appleCloud.route == .appleCloud && claude.route == .claude,
                     "Each provider must match its route")
        self.providers = [.onDevice: onDevice, .appleCloud: appleCloud, .claude: claude]
        self.costTable = costTable
        let models = RouteModels(onDevice: onDevice.model, appleCloud: appleCloud.model, claude: claude.model)
        self.session = LanguageModelSession(
            profile: RoutingProfile(instructions: instructions, models: models),
            history: history
        )
        session.transcriptErrorHandlingPolicy = .revertTranscript
    }

    public var transcript: Transcript { session.transcript }

    public func provider(for route: Route) -> any ModelProvider {
        // Every route is filled in init.
        providers[route]!
    }

    public func availability(of route: Route) -> ProviderAvailability {
        provider(for: route).availability
    }

    /// Loads the route's model ahead of the next turn, so its first reply starts sooner.
    /// Call it when the user picks a route or the app comes to the foreground.
    public func prewarm(_ route: Route) {
        guard !isResponding, provider(for: route).availability.isAvailable else { return }
        session.properties.activeRoute = route
        session.prewarm()
    }

    /// Runs one turn on the decided route, reporting the cumulative text as it streams.
    public func respond(
        to prompt: String,
        decision: RouteDecision,
        onPartial: (String) -> Void = { _ in }
    ) async throws -> TurnResult {
        guard !isResponding else { throw Error.busy }
        let provider = provider(for: decision.route)
        if case .unavailable(let reason) = provider.availability {
            throw Error.routeUnavailable(decision.route, reason: reason)
        }

        isResponding = true
        defer { isResponding = false }
        session.properties.activeRoute = decision.route

        let usageBefore = session.usage
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: ContinuousClock.Instant?
        var text = ""

        for try await snapshot in session.streamResponse(to: prompt) {
            if firstToken == nil, !snapshot.content.isEmpty {
                firstToken = clock.now
            }
            text = snapshot.content
            onPartial(text)
        }

        let usage = TokenUsage(
            difference: session.usage,
            minus: usageBefore,
            reportsReasoning: decision.route != .claude
        )
        let metrics = StepMetrics(
            decision: decision,
            modelID: provider.modelID,
            timeToFirstToken: firstToken.map { (start.duration(to: $0)).seconds },
            totalLatency: start.duration(to: clock.now).seconds,
            usage: usage,
            estimatedCost: costTable.cost(of: usage, modelID: provider.modelID)
        )
        return TurnResult(text: text, metrics: metrics)
    }
}

extension TokenUsage {
    /// This turn's tokens, from the session's cumulative usage before and after it.
    /// Claude bills thinking as output and always reports 0 reasoning tokens, so it gets nil.
    init(difference after: LanguageModelSession.Usage, minus before: LanguageModelSession.Usage, reportsReasoning: Bool) {
        self.init(
            input: after.input.totalTokenCount - before.input.totalTokenCount,
            cachedInput: after.input.cachedTokenCount - before.input.cachedTokenCount,
            output: after.output.totalTokenCount - before.output.totalTokenCount,
            reasoning: reportsReasoning
                ? after.output.reasoningTokenCount - before.output.reasoningTokenCount
                : nil
        )
    }
}

extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
