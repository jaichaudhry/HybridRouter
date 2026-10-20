import Foundation
import FoundationModels
import Observation
import HybridRouterKit
import HybridRouterKitVoice

/// One message in the chat list.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable, Codable { case user, assistant }

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

/// Saved without the in-flight state: a restored message is never streaming.
extension ChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, decision, steps, errorMessage, privacyReason, routeIsSimulated,
             attachmentNames, attachments, previousRoutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            role: try container.decode(Role.self, forKey: .role),
            content: try container.decode(TurnContent.self, forKey: .content),
            decision: try container.decodeIfPresent(RouteDecision.self, forKey: .decision),
            steps: try container.decode([StepMetrics].self, forKey: .steps),
            errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
            privacyReason: try container.decodeIfPresent(String.self, forKey: .privacyReason),
            attachmentNames: try container.decode([String].self, forKey: .attachmentNames),
            attachments: try container.decode([AttachmentPreview].self, forKey: .attachments)
        )
        routeIsSimulated = try container.decode(Bool.self, forKey: .routeIsSimulated)
        previousRoutes = try container.decode([Route].self, forKey: .previousRoutes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(decision, forKey: .decision)
        try container.encode(steps, forKey: .steps)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(privacyReason, forKey: .privacyReason)
        try container.encode(routeIsSimulated, forKey: .routeIsSimulated)
        try container.encode(attachmentNames, forKey: .attachmentNames)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(previousRoutes, forKey: .previousRoutes)
    }
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

    /// Speech-to-text for the composer, on the device. What's heard fills the draft, which then
    /// goes through the same privacy check and routing as typing.
    public let voice = VoiceInput()
    /// Extra names the speech model should expect, e.g. places in a travel scenario.
    public var voiceVocabulary: [String] = []
    /// Why listening couldn't start, if it couldn't.
    public private(set) var voiceError: String?
    /// The draft before listening started; what's heard is added after it.
    @ObservationIgnored private var draftBeforeVoice = ""

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

    /// Builds a session that continues a conversation: its history, private turns and last route.
    public typealias SessionFactory = (_ conversation: RestoredConversation) -> RoutedSession

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

    // MARK: Saving

    /// Continues a saved chat. `makeSession` builds the session from its conversation, with the
    /// scenario's current instructions and the app's current models.
    /// - Throws: if the chat was saved by a newer version.
    public convenience init(
        restoring saved: SavedChat,
        makeSession: SessionFactory,
        coordinator: TurnCoordinator,
        costTable: CostTable,
        structuredOutputs: [StructuredOutput] = []
    ) throws {
        let conversation = try saved.conversation.restore()
        self.init(session: makeSession(conversation), coordinator: coordinator, costTable: costTable, structuredOutputs: structuredOutputs)
        messages = saved.messages
        routeOverride = saved.routeOverride
        restoredConservatively = conversation.isConservative
    }

    /// The saved chat's private turns didn't line up with its conversation, so the cloud model
    /// sees none of its earlier messages. Shown as a note.
    public private(set) var restoredConservatively = false

    /// Called after each turn finishes (answered, failed or blocked), never while a reply streams.
    /// For saving the chat.
    @ObservationIgnored public var onTurnFinished: (@MainActor () -> Void)?

    /// This chat, to save with ``ChatStore``.
    public func savedChat(id: UUID, scenarioID: String, createdAt: Date) -> SavedChat {
        SavedChat(
            id: id,
            scenarioID: scenarioID,
            title: Self.title(for: messages),
            createdAt: createdAt,
            updatedAt: .now,
            messages: messages.filter { !$0.isStreaming },
            conversation: session.snapshot(),
            routeOverride: routeOverride
        )
    }

    /// The first message, shortened, or "New chat".
    static func title(for messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user })?.content.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return "New chat" }
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    public var canSend: Bool {
        !isSending && !isListening && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public var steps: [StepMetrics] { messages.flatMap(\.steps) }

    public var summary: SessionSummary {
        SessionSummary(steps: steps, costTable: costTable, cloudModelID: session.provider(for: .cloud).modelID)
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
        onTurnFinished?()
    }

    // MARK: Voice

    public var isListening: Bool { voice.state != .idle }

    /// Starts listening; what's heard fills the draft as it's spoken.
    public func startListening() async {
        guard !isListening else { return }
        voiceError = nil
        voice.vocabulary = VoiceInput.routeNames(session.labels) + voiceVocabulary
        draftBeforeVoice = draft
        do {
            try await voice.start()
        } catch {
            voiceError = error.localizedDescription
        }
    }

    /// Stops listening and leaves the final words in the draft, to check before sending.
    public func stopListening() async {
        guard isListening else { return }
        let transcript = await voice.stop()
        draft = Self.joined(draftBeforeVoice, transcript.text)
    }

    /// Keeps the draft showing what's been heard so far. Called as the transcript changes.
    public func voiceTextChanged() {
        guard voice.state == .listening else { return }
        draft = Self.joined(draftBeforeVoice, voice.text)
    }

    static func joined(_ typed: String, _ spoken: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        return [typed, spoken].filter { !$0.isEmpty }.joined(separator: " ")
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
        session = makeSession(RestoredConversation(
            history: Array(session.transcript),
            privatePromptIDs: session.privatePromptIDs,
            lastRoute: session.lastRoute
        ))
    }

    /// Exports every step's metrics as JSON.
    public func exportMetrics() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(steps)
    }
}
