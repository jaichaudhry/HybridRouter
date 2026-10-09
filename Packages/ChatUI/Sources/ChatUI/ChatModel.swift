import Foundation
import FoundationModels
import Observation
import RouterKit

/// One message in the chat list.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var content: TurnContent
    /// Nil while the router is still choosing.
    public var decision: RouteDecision?
    /// Every model step behind this reply, including escalated attempts.
    public var steps: [StepMetrics]
    public var isStreaming: Bool
    public var errorMessage: String?
    /// Why the turn was kept off Claude, if it was private.
    public var privacyReason: String?
    /// Names of the files and images attached to a user message.
    public var attachmentNames: [String]

    public init(
        id: UUID = UUID(),
        role: Role,
        content: TurnContent,
        decision: RouteDecision? = nil,
        steps: [StepMetrics] = [],
        isStreaming: Bool = false,
        errorMessage: String? = nil,
        privacyReason: String? = nil,
        attachmentNames: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.decision = decision
        self.steps = steps
        self.isStreaming = isStreaming
        self.errorMessage = errorMessage
        self.privacyReason = privacyReason
        self.attachmentNames = attachmentNames
    }

    /// Metrics for the step that produced the reply.
    public var metrics: StepMetrics? { steps.last }
}

/// Chat state for one conversation. Scenario-agnostic: the app supplies the router setup,
/// tools and structured output through the session and coordinator.
@MainActor
@Observable
public final class ChatModel {
    public private(set) var messages: [ChatMessage] = []
    /// True from the moment a message is sent until its reply finishes, including routing.
    public private(set) var isSending = false
    public var draft = ""
    /// The composer's Private toggle: the next message stays off Claude.
    public var isPrivate = false
    /// Attachments for the next message.
    public var attachments: [ChatAttachment] = []
    /// Whether every attached image is private (Document Helper's scans and photos).
    public var imagesArePrivate = false
    /// Nil means Auto. Picking a route starts loading its model right away.
    public var routeOverride: Route? {
        didSet { prewarm() }
    }

    public private(set) var session: RoutedSession
    public var coordinator: TurnCoordinator
    public var structuredOutputs: [StructuredOutput]
    @ObservationIgnored private let costTable: CostTable
    @ObservationIgnored private let privacyGuard = PrivacyGuard()
    /// A session swap requested mid-reply, applied when the reply finishes.
    @ObservationIgnored private var pendingSession: (([Transcript.Entry]) -> RoutedSession)?

    public init(
        session: RoutedSession,
        coordinator: TurnCoordinator,
        costTable: CostTable,
        structuredOutputs: [StructuredOutput] = []
    ) {
        self.session = session
        self.coordinator = coordinator
        self.costTable = costTable
        self.structuredOutputs = structuredOutputs
    }

    public var canSend: Bool {
        !isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public var steps: [StepMetrics] { messages.flatMap(\.steps) }

    public var summary: SessionSummary {
        SessionSummary(steps: steps, costTable: costTable, claudeModelID: session.provider(for: .claude).modelID)
    }

    /// Sends the draft, or `text` if given (e.g. a sample-prompt chip).
    public func send(_ text: String? = nil) async {
        var prompt = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachments
        guard !isSending, !prompt.isEmpty || !attachments.isEmpty else { return }
        isSending = true
        defer {
            isSending = false
            applyPendingSession()
        }
        if text == nil { draft = "" }
        self.attachments = []
        let markedPrivate = isPrivate
        isPrivate = false
        if prompt.isEmpty { prompt = "Describe the attachment." }

        let images = attachments.compactMap(\.image)
        let documents = attachments.filter { $0.documentText != nil }
        let fullPrompt = documents.reduce(prompt) { text, document in
            text + "\n\nDocument \"\(document.name)\":\n\(document.documentText ?? "")"
        }
        let reason = privacyGuard.assess(
            fullPrompt,
            markedPrivate: markedPrivate,
            fromScan: attachments.contains(where: \.isScan) || (imagesArePrivate && !images.isEmpty)
        )

        messages.append(ChatMessage(
            role: .user,
            content: .text(prompt),
            privacyReason: reason?.label,
            attachmentNames: attachments.map(\.name)
        ))
        messages.append(ChatMessage(role: .assistant, content: .text(""), isStreaming: true, privacyReason: reason?.label))
        let index = messages.count - 1

        let request = TurnCoordinator.Request(
            prompt: fullPrompt,
            images: images,
            override: routeOverride,
            privacyReason: reason?.label,
            structuredOutputs: structuredOutputs
        )
        let outcome = await coordinator.run(request, in: session) { [weak self] event in
            guard let self else { return }
            switch event {
            case .routed(let decision):
                // A new route (first pick or escalation) starts the reply over.
                messages[index].decision = decision
                messages[index].content = .text("")
            case .partial(let content):
                messages[index].content = content
            }
        }

        messages[index].steps = outcome.steps
        messages[index].decision = outcome.decision ?? messages[index].decision
        // A failed turn's half-streamed text was already dropped from the session (the
        // transcript reverts on error), so don't leave it on screen either.
        messages[index].content = outcome.content ?? .text("")
        messages[index].errorMessage = outcome.failure
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
        return try encoder.encode(steps)
    }
}
