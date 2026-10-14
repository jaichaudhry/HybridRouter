import Foundation
import FoundationModels
import Observation
import HybridRouterKit

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
    /// The chosen route is served by a stand-in model (e.g. Apple Cloud simulated on-device).
    public var routeIsSimulated = false
    /// Names of the files and images attached to a user message.
    public var attachmentNames: [String]
    /// Thumbnails and names of a user message's attachments, for display.
    public var attachments: [AttachmentPreview] = []
    /// Routes this reply tried before the current one, oldest first (escalation).
    public var previousRoutes: [Route] = []
    /// When the current route was chosen, for the "waiting for the first token" timer.
    public var routedAt: Date?

    public init(
        id: UUID = UUID(),
        role: Role,
        content: TurnContent,
        decision: RouteDecision? = nil,
        steps: [StepMetrics] = [],
        isStreaming: Bool = false,
        errorMessage: String? = nil,
        privacyReason: String? = nil,
        attachmentNames: [String] = [],
        attachments: [AttachmentPreview] = []
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
        self.attachments = attachments
    }

    /// Metrics for the step that produced the reply.
    public var metrics: StepMetrics? { steps.last }
}

/// Limits how often streamed text reaches the screen. Each update re-renders the reply and
/// re-parses its Markdown, and snapshots can arrive many times a second.
struct StreamThrottle {
    static let interval: Duration = .milliseconds(100)
    private let clock = ContinuousClock()
    private var lastUpdate: ContinuousClock.Instant?

    mutating func shouldUpdate() -> Bool {
        let now = clock.now
        if let lastUpdate, lastUpdate.duration(to: now) < Self.interval { return false }
        lastUpdate = now
        return true
    }
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
    /// Attachments for the next message. Images start being read (OCR) as soon as they're
    /// attached, so the text is usually ready by the time the message is sent.
    public var attachments: [ChatAttachment] = [] {
        didSet { startReadingImages() }
    }
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
    /// The attempt in progress, so "Answer on-device instead" can stop it.
    @ObservationIgnored private var currentTurn: Task<TurnCoordinator.Outcome, Never>?
    @ObservationIgnored private var switchesToOnDevice = false
    /// Text recognition in progress or done, by attachment.
    @ObservationIgnored private var imageText: [UUID: Task<String?, Never>] = [:]
    /// A session swap requested mid-reply, applied when the reply finishes.
    @ObservationIgnored private var pendingSession: SessionFactory?

    /// Builds a session from the previous one's history and private turns.
    public typealias SessionFactory = (_ history: [Transcript.Entry], _ privatePromptIDs: Set<String>) -> RoutedSession

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
        let originalDraft = draft
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
        var fullPrompt = documents.reduce(prompt) { text, document in
            text + "\n\nDocument \"\(document.name)\":\n\(document.documentText ?? "")"
        }
        // The images' text, read on-device. Models answer from it instead of having to
        // remember to call an OCR tool (the on-device model sometimes didn't, and made up a
        // receipt instead).
        for attachment in attachments where attachment.image != nil {
            if let text = await recognizedText(of: attachment) {
                fullPrompt += "\n\nText read on-device from \"\(attachment.name)\":\n\(text)"
            }
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
            attachmentNames: attachments.map(\.name),
            attachments: attachments.map(\.preview)
        ))
        messages.append(ChatMessage(role: .assistant, content: .text(""), isStreaming: true, privacyReason: reason?.label))
        let index = messages.count - 1

        var request = TurnCoordinator.Request(
            prompt: fullPrompt,
            images: images,
            override: routeOverride,
            privacyReason: reason?.label,
            structuredOutputs: structuredOutputs
        )
        var outcome = await runTurn(request, into: index)
        // "Answer on-device instead" stops the turn while it waits for its first token, then
        // asks again on-device. The abandoned attempt's steps stay in the metrics.
        var earlierSteps: [StepMetrics] = []
        while switchesToOnDevice {
            switchesToOnDevice = false
            earlierSteps += outcome.steps
            request.override = .onDevice
            outcome = await runTurn(request, into: index)
        }
        outcome.steps = earlierSteps + outcome.steps

        messages[index].steps = outcome.steps
        messages[index].decision = outcome.decision ?? messages[index].decision
        // A failed turn's half-streamed text was already dropped from the session (the
        // transcript reverts on error), so don't leave it on screen either.
        messages[index].content = outcome.content ?? .text("")
        messages[index].errorMessage = outcome.failure
        messages[index].isStreaming = false

        // Nothing was answered (e.g. blocked as private, or offline): give the user back their
        // draft, attachments and Private toggle so scans don't have to be redone, unless they've
        // already started a new message.
        if outcome.content == nil, draft.isEmpty, self.attachments.isEmpty {
            if text == nil { draft = originalDraft }
            self.attachments = attachments
            isPrivate = markedPrivate
        }
    }

    /// Whether the reply in progress can be switched to on-device: it's still waiting for its
    /// first token on another route, and the on-device model is available.
    public var canAnswerOnDevice: Bool {
        guard isSending, currentTurn != nil, let reply = messages.last, reply.role == .assistant,
              let route = reply.decision?.route, route != .onDevice, reply.content.isEmpty else { return false }
        return session.availability(of: .onDevice).isAvailable
    }

    /// Stops waiting for the current route and answers on-device instead, like "Answer now".
    public func answerOnDeviceInstead() {
        guard canAnswerOnDevice else { return }
        switchesToOnDevice = true
        currentTurn?.cancel()
    }

    /// Runs one attempt at the turn, streaming into the message at `index`. Cancellable through
    /// `currentTurn`, and cancelled with the caller.
    private func runTurn(_ request: TurnCoordinator.Request, into index: Int) async -> TurnCoordinator.Outcome {
        let turn = Task { [coordinator, session] in
            // At most about ten screen updates a second while streaming; the final text always lands.
            var throttle = StreamThrottle()
            return await coordinator.run(request, in: session) { [weak self] event in
                guard let self else { return }
                switch event {
                case .routed(let decision):
                    // A new route (first pick, escalation or a switch) starts the reply over.
                    if let previous = messages[index].decision?.route, previous != decision.route {
                        messages[index].previousRoutes.append(previous)
                    }
                    messages[index].decision = decision
                    messages[index].routedAt = .now
                    messages[index].routeIsSimulated = session.provider(for: decision.route).isSimulated
                    messages[index].content = .text("")
                case .partial(let content):
                    if throttle.shouldUpdate() {
                        messages[index].content = content
                    }
                }
            }
        }
        currentTurn = turn
        defer { currentTurn = nil }
        return await withTaskCancellationHandler {
            await turn.value
        } onCancel: {
            turn.cancel()
        }
    }

    private func startReadingImages() {
        let ids = Set(attachments.map(\.id))
        imageText = imageText.filter { ids.contains($0.key) }
        for attachment in attachments where imageText[attachment.id] == nil {
            guard let image = attachment.image else { continue }
            imageText[attachment.id] = Task { await TextRecognizer.text(in: image) }
        }
    }

    private func recognizedText(of attachment: ChatAttachment) async -> String? {
        if let task = imageText[attachment.id] {
            return await task.value
        }
        guard let image = attachment.image else { return nil }
        return await TextRecognizer.text(in: image)
    }

    /// Loads the model the next message will most likely use, so its first reply starts sooner.
    /// On Auto that's the cheapest available route.
    public func prewarm() {
        let route = routeOverride ?? Route.allCases.first { session.availability(of: $0).isAvailable }
        if let route { session.prewarm(route) }
        // The classifier runs its own short on-device request before every turn; warm it too.
        Task(priority: .utility) { [coordinator] in await coordinator.prewarm() }
    }

    /// Swaps in a new session (e.g. after Claude credentials change) that continues the same
    /// conversation. If a reply is in progress, the swap happens as soon as it finishes.
    public func replaceSession(_ makeSession: @escaping SessionFactory) {
        pendingSession = makeSession
        if !isSending { applyPendingSession() }
    }

    private func applyPendingSession() {
        guard let makeSession = pendingSession else { return }
        pendingSession = nil
        session = makeSession(Array(session.transcript), session.privatePromptIDs)
    }

    /// Exports every step's metrics as JSON.
    public func exportMetrics() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(steps)
    }
}
