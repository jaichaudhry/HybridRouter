import Foundation
import FoundationModels
import Observation
import RouterKit

/// One message in the chat list.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var text: String
    public var decision: RouteDecision?
    public var metrics: StepMetrics?
    public var isStreaming: Bool
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        decision: RouteDecision? = nil,
        metrics: StepMetrics? = nil,
        isStreaming: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.decision = decision
        self.metrics = metrics
        self.isStreaming = isStreaming
        self.errorMessage = errorMessage
    }
}

/// Chat state for one conversation. Scenario-agnostic: the app supplies how Auto picks a route.
@MainActor
@Observable
public final class ChatModel {
    public typealias AutoRouter = @MainActor (String, RoutedSession) async -> RouteDecision

    public private(set) var messages: [ChatMessage] = []
    /// True from the moment a message is sent until its reply finishes, including route selection.
    public private(set) var isSending = false
    public var draft = ""
    /// Nil means Auto. Picking a route starts loading its model right away.
    public var routeOverride: Route? {
        didSet { prewarm() }
    }

    public private(set) var session: RoutedSession
    @ObservationIgnored private let autoRouter: AutoRouter
    /// A session swap requested mid-reply, applied when the reply finishes.
    @ObservationIgnored private var pendingSession: (([Transcript.Entry]) -> RoutedSession)?
    @ObservationIgnored private let costTable: CostTable

    public init(session: RoutedSession, costTable: CostTable, autoRouter: @escaping AutoRouter = ChatModel.firstAvailable) {
        self.session = session
        self.costTable = costTable
        self.autoRouter = autoRouter
    }

    public var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var steps: [StepMetrics] { messages.compactMap(\.metrics) }

    public var summary: SessionSummary {
        SessionSummary(steps: steps, costTable: costTable, claudeModelID: session.provider(for: .claude).modelID)
    }

    /// Sends the draft, or `text` if given (e.g. a sample-prompt chip).
    public func send(_ text: String? = nil) async {
        let prompt = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        isSending = true
        defer {
            isSending = false
            applyPendingSession()
        }
        if text == nil { draft = "" }

        messages.append(ChatMessage(role: .user, text: prompt))
        let decision: RouteDecision = if let routeOverride {
            .forced(routeOverride)
        } else {
            await autoRouter(prompt, session)
        }
        messages.append(ChatMessage(role: .assistant, text: "", decision: decision, isStreaming: true))
        let index = messages.count - 1

        do {
            let result = try await session.respond(to: prompt, decision: decision) { [weak self] partial in
                self?.messages[index].text = partial.text
            }
            messages[index].text = result.text
            messages[index].metrics = result.metrics
        } catch let error as RoutedSession.Error {
            messages[index].errorMessage = Self.describe(error)
        } catch {
            messages[index].errorMessage = error.localizedDescription
        }
        messages[index].isStreaming = false
    }

    /// Loads the model the next message will most likely use, so its first reply starts sooner.
    /// On Auto that's the cheapest available route.
    public func prewarm() {
        let route = routeOverride ?? Route.allCases.first { session.availability(of: $0).isAvailable }
        if let route { session.prewarm(route) }
    }

    /// Swaps in a new session (e.g. after Claude credentials change) that continues the same
    /// conversation. If a reply is in progress, the swap happens as soon as it finishes.
    public func replaceSession(_ makeSession: @escaping ([Transcript.Entry]) -> RoutedSession) {
        pendingSession = makeSession
        if !isSending { applyPendingSession() }
    }

    private func applyPendingSession() {
        guard let makeSession = pendingSession else { return }
        pendingSession = nil
        session = makeSession(Array(session.transcript))
    }

    /// Exports every step's metrics as JSON (SPEC §9).
    public func exportMetrics() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(steps)
    }

    /// M1 default for Auto: the cheapest available route. The real router arrives in M2.
    public static func firstAvailable(_ prompt: String, _ session: RoutedSession) async -> RouteDecision {
        for route in Route.allCases where session.availability(of: route).isAvailable {
            return RouteDecision(route: route, reason: "Cheapest available route", source: .rule)
        }
        return RouteDecision(route: .onDevice, reason: "No route is available", source: .rule)
    }

    static func describe(_ error: RoutedSession.Error) -> String {
        switch error {
        case .routeUnavailable(let route, let reason): "\(route.displayName) unavailable: \(reason)"
        case .busy: "Still answering the previous message"
        }
    }
}
