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

    /// A step that failed after it started, with what it used before failing.
    public struct StepFailure: Swift.Error {
        public let underlying: any Swift.Error
        public let metrics: StepMetrics
    }

    public struct TurnResult: Sendable {
        public let content: TurnContent
        public let metrics: StepMetrics

        /// The reply as text (structured replies as JSON).
        public var text: String { content.text }
    }

    public private(set) var isResponding = false
    /// The route of the last reply that succeeded.
    public private(set) var lastRoute: Route?

    @ObservationIgnored private let session: LanguageModelSession
    @ObservationIgnored private let providers: [Route: any ModelProvider]
    @ObservationIgnored private let costTable: CostTable
    @ObservationIgnored private let privacy: PrivacyLedger
    /// Text sent with every request besides the transcript: instructions, the longest route
    /// note and tool descriptions. Counted by the context-fit estimate.
    @ObservationIgnored public let fixedPromptText: String
    /// How much of the conversation each route sees.
    @ObservationIgnored public let historyPolicy: HistoryPolicy

    /// - Parameters:
    ///   - instructions: the app's system instructions, shared by every route.
    ///   - tools: tools every route may call.
    ///   - appleOnlyTools: tools for the Apple routes only, e.g. ones that read attachments by label.
    ///   - onDevice, appleCloud, cloud: the provider for each route. A provider whose `route`
    ///     doesn't match its slot reports the route unavailable instead of serving it.
    ///   - history: an earlier conversation to continue.
    ///   - privatePromptIDs: earlier private turns, from ``privatePromptIDs`` on the old session.
    ///   - historyPolicy: how much of the conversation each route sees.
    ///   - lastRoute: the route of the last reply in `history`, so a bare follow-up stays on it.
    public init(
        instructions: String,
        tools: [any Tool] = [],
        appleOnlyTools: [any Tool] = [],
        onDevice: any ModelProvider,
        appleCloud: any ModelProvider,
        cloud: any ModelProvider,
        costTable: CostTable,
        history: [Transcript.Entry] = [],
        privatePromptIDs: Set<String> = [],
        historyPolicy: HistoryPolicy = .full,
        lastRoute: Route? = nil
    ) {
        self.historyPolicy = historyPolicy
        self.lastRoute = lastRoute
        // Rebuilt sessions (e.g. after a Claude key change) must keep withholding earlier private turns.
        self.privacy = PrivacyLedger(privatePromptIDs: privatePromptIDs)
        let slotted: [any ModelProvider] = [(Route.onDevice, onDevice), (.appleCloud, appleCloud), (.cloud, cloud)].map { route, provider -> any ModelProvider in
            provider.route == route ? provider : MisplacedProvider(wrapped: provider, slot: route)
        }
        self.providers = Dictionary(uniqueKeysWithValues: slotted.map { ($0.route, $0) })
        self.costTable = costTable
        let models = RouteModels(onDevice: slotted[0], appleCloud: slotted[1], cloud: slotted[2])
        let longestNote = Route.allCases.map { RoutingProfile.routeNote(for: $0, models: models.names) }.max { $0.count < $1.count } ?? ""
        let toolText = (tools + appleOnlyTools).map { "\($0.name): \($0.description)" }
        self.fixedPromptText = ([instructions, longestNote] + toolText).joined(separator: "\n")
        self.session = LanguageModelSession(
            profile: RoutingProfile(
                instructions: instructions,
                tools: tools,
                appleOnlyTools: appleOnlyTools,
                models: models,
                privacy: privacy,
                history: historyPolicy
            ),
            history: history
        )
        session.transcriptErrorHandlingPolicy = .revertTranscript
    }

    @available(*, deprecated, renamed: "init(instructions:tools:appleOnlyTools:onDevice:appleCloud:cloud:costTable:history:privatePromptIDs:)")
    public convenience init(
        instructions: String,
        tools: [any Tool] = [],
        appleOnlyTools: [any Tool] = [],
        onDevice: any ModelProvider,
        appleCloud: any ModelProvider,
        claude: any ModelProvider,
        costTable: CostTable,
        history: [Transcript.Entry] = [],
        privatePromptIDs: Set<String> = []
    ) {
        self.init(
            instructions: instructions, tools: tools, appleOnlyTools: appleOnlyTools,
            onDevice: onDevice, appleCloud: appleCloud, cloud: claude,
            costTable: costTable, history: history, privatePromptIDs: privatePromptIDs
        )
    }

    public var transcript: Transcript { session.transcript }

    /// Route names, with the cloud route named for the model serving it.
    public var labels: RouteLabels {
        RouteLabels(cloud: provider(for: .cloud))
    }

    /// Prompt IDs of turns the cloud model must only see as placeholders. Pass them to a rebuilt session.
    public var privatePromptIDs: Set<String> { privacy.privatePromptIDs }

    /// The text of the most recent user message in the history, if any.
    public var lastPromptText: String? {
        guard case .prompt(let prompt) = session.transcript.last(where: \.isPrompt) else { return nil }
        let text = prompt.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { text.content } else { nil }
        }.joined()
        return text.isEmpty ? nil : text
    }

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
        privacy.route = route
        session.prewarm()
    }

    /// Runs one turn on the decided route, reporting the cumulative reply as it streams.
    /// - Parameters:
    ///   - prompt: the user's message.
    ///   - images: attached to the prompt with their labels.
    ///   - decision: the route to run on, and why.
    ///   - schema: if set, the reply is structured content matching it.
    ///   - isPrivate: the turn is private, so the cloud model only ever sees placeholders for it.
    ///   - onPartial: called with the reply so far as it streams.
    public func respond(
        to prompt: String,
        images: [ImageInput] = [],
        decision: RouteDecision,
        schema: GenerationSchema? = nil,
        isPrivate: Bool = false,
        onPartial: (TurnContent) -> Void = { _ in }
    ) async throws -> TurnResult {
        guard !isResponding else { throw Error.busy }
        let provider = provider(for: decision.route)
        if case .unavailable(let reason) = provider.availability {
            throw Error.routeUnavailable(decision.route, reason: reason)
        }

        isResponding = true
        defer { isResponding = false }
        session.properties.activeRoute = decision.route
        privacy.route = decision.route
        privacy.turnLimit = decision.historyBudget.map(HistoryPolicy.Limit.tokens)
        privacy.seen = nil
        defer { privacy.turnLimit = nil }

        let usageBefore = session.usage
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: ContinuousClock.Instant?
        var content = schema == nil ? TurnContent.text("") : .structured(GeneratedContent(properties: [:]))

        func receive(_ next: TurnContent) {
            if firstToken == nil, !next.isEmpty { firstToken = clock.now }
            content = next
            onPartial(next)
        }
        func metrics() -> StepMetrics {
            let usage = TokenUsage(
                difference: session.usage,
                minus: usageBefore,
                reportsReasoning: decision.route != .cloud
            )
            var metrics = StepMetrics(
                decision: decision,
                modelID: provider.modelID,
                timeToFirstToken: firstToken.map { (start.duration(to: $0)).seconds },
                totalLatency: start.duration(to: clock.now).seconds,
                usage: usage,
                estimatedCost: costTable.cost(of: usage, modelID: provider.modelID)
            )
            metrics.isSimulated = provider.isSimulated
            if let seen = privacy.seen {
                metrics.earlierTurnsSeen = seen.seen
                metrics.earlierTurns = seen.total
            }
            return metrics
        }

        let fullPrompt = Self.prompt(prompt, images: images)
        do {
            if let schema {
                for try await snapshot in session.streamResponse(to: fullPrompt, schema: schema) {
                    receive(.structured(snapshot.rawContent))
                }
            } else {
                for try await snapshot in session.streamResponse(to: fullPrompt) {
                    receive(.text(snapshot.content))
                }
            }
        } catch {
            throw StepFailure(underlying: error, metrics: metrics())
        }
        lastRoute = decision.route
        // Once a conversation has a private turn, later turns on Apple routes saw it and may
        // repeat or re-read it (e.g. "list the items again" re-runs OCR on a private scan), so
        // they're withheld from the cloud model too. Its own turns never saw private content.
        let derivesFromPrivate = !privacy.privatePromptIDs.isEmpty && decision.route != .cloud
        if isPrivate || derivesFromPrivate, case .prompt(let entry) = session.transcript.last(where: \.isPrompt) {
            privacy.markPrivate(promptID: entry.id)
        }
        return TurnResult(content: content, metrics: metrics())
    }

    /// The text plus labeled image attachments. Labels are also named in the text: the model
    /// has to pass them to image tools such as OCRTool.
    static func prompt(_ text: String, images: [ImageInput]) -> Prompt {
        guard !images.isEmpty else { return Prompt(text) }
        let labels = images.map(\.label).joined(separator: ", ")
        return Prompt {
            "\(text)\n(Attached image: \(labels))"
            for image in images {
                Attachment(image.cgImage, orientation: image.orientation).label(image.label)
            }
        }
    }

    /// Removes the most recent turn (its prompt and everything after it) from the history,
    /// so a failed attempt that returned normally (e.g. an empty reply) can be retried cleanly.
    public func discardLastTurn() {
        guard !isResponding else { return }
        session.transcript.history.removeLastTurn()
    }
}

extension Transcript.HistoryView {
    /// Removes the last prompt and everything after it. Indices are only valid on the view
    /// they came from, so the search and removal happen on the same instance.
    mutating func removeLastTurn() {
        guard let lastPrompt = lastIndex(where: \.isPrompt) else { return }
        removeSubrange(lastPrompt...)
    }
}

/// A reply: plain text, or structured content generated from a schema.
public enum TurnContent: Equatable, Sendable, Codable {
    case text(String)
    case structured(GeneratedContent)

    public var text: String {
        switch self {
        case .text(let text): text
        case .structured(let content): content.jsonString
        }
    }

    private enum CodingKeys: String, CodingKey { case text, structured }

    /// Structured content is stored as its JSON, which `GeneratedContent(json:)` reads back.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let json = try container.decodeIfPresent(String.self, forKey: .structured) {
            self = .structured(try GeneratedContent(json: json))
        } else {
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try container.encode(text, forKey: .text)
        case .structured(let content): try container.encode(content.jsonString, forKey: .structured)
        }
    }

    /// True when nothing visible has been generated.
    public var isEmpty: Bool {
        switch self {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .structured(let content): content.jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "{}[] \n")).isEmpty
        }
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
