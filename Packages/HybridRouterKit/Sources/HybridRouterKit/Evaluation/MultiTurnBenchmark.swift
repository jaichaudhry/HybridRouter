import Foundation

/// Measures routing over whole conversations. Each conversation runs from start to finish under
/// each strategy (the router, always on-device, always the cloud model), since answers diverge
/// after the first turn, and a judge grades every turn with the conversation so far in view.
///
/// Four groups: follow-ups ("Why?", "Shorter"), privacy (a private turn, then ordinary ones),
/// long chats (a pasted document, then questions about its early details) and failures (the
/// cloud model's requests fail on chosen turns). Shared by the Mac tests and the in-app screen.
public enum MultiTurnBenchmark {
    public struct Dataset: Codable, Sendable {
        public let version: Int
        public let notes: String?
        public let documents: [String: Document]
        public let conversations: [Conversation]

        public init(version: Int = 1, notes: String? = nil, documents: [String: Document] = [:], conversations: [Conversation]) {
            self.version = version
            self.notes = notes
            self.documents = documents
            self.conversations = conversations
        }

        public static func load(_ data: Data) throws -> Dataset {
            try JSONDecoder().decode(Dataset.self, from: data)
        }

        /// What the user sends for a turn: any pasted document, then the prompt.
        public func message(for turn: Turn) -> String {
            guard let key = turn.document, let document = documents[key] else { return turn.prompt }
            return "\(document.text)\n\n\(turn.prompt)"
        }
    }

    public struct Document: Codable, Sendable, Hashable {
        public let title: String
        public let text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public enum Group: String, Codable, Sendable, CaseIterable {
        case followUp, privacy, longChat, failure

        public var displayName: String {
            switch self {
            case .followUp: "Follow-ups"
            case .privacy: "Privacy"
            case .longChat: "Long chats"
            case .failure: "Failures"
            }
        }
    }

    public struct Conversation: Codable, Sendable, Identifiable, Hashable {
        public let id: String
        /// "tuning" conversations may guide routing changes; "heldout" ones confirm them.
        public let split: String
        public let group: Group
        public let title: String
        /// Text from private turns that must never reach the cloud model on the router.
        public let secrets: [String]?
        public let faults: [Fault]?
        public let turns: [Turn]

        public init(id: String, split: String = "tuning", group: Group, title: String,
                    secrets: [String]? = nil, faults: [Fault]? = nil, turns: [Turn]) {
            self.id = id
            self.split = split
            self.group = group
            self.title = title
            self.secrets = secrets
            self.faults = faults
            self.turns = turns
        }

        /// Failure conversations measure retries, so only the router runs them.
        public var strategies: [Strategy] {
            group == .failure ? [.router] : Strategy.allCases
        }

        /// Faults to inject on a turn, by its 0-based index.
        public func faults(onTurn index: Int) -> [Fault] {
            (faults ?? []).filter { $0.turn == index + 1 }
        }
    }

    public struct Turn: Codable, Sendable, Hashable {
        public let prompt: String
        /// A key into ``Dataset/documents``, pasted before the prompt.
        public let document: String?
        /// What a correct answer must contain, for the judge.
        public let criteria: String?
        public let tags: [Tag]?
        /// The user turned on Private for this message.
        public let markedPrivate: Bool?

        public init(prompt: String, document: String? = nil, criteria: String? = nil, tags: [Tag]? = nil, markedPrivate: Bool? = nil) {
            self.prompt = prompt
            self.document = document
            self.criteria = criteria
            self.tags = tags
            self.markedPrivate = markedPrivate
        }

        public func has(_ tag: Tag) -> Bool { tags?.contains(tag) ?? false }
    }

    public enum Tag: String, Codable, Sendable {
        /// Builds on the previous turn without restating it.
        case followUp
        /// A follow-up that needs more than the turn before it.
        case harder
        /// One short, checkable answer.
        case exact
        /// The privacy guard should keep this turn off the cloud model.
        case `private`
        /// Builds on a private turn but has no private detail itself.
        case afterPrivate
        /// Asks about a detail from early in a long chat.
        case recall
    }

    /// Makes the cloud model's next requests fail on a turn.
    public struct Fault: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case rateLimited, timeout, network
        }

        /// 1-based.
        public let turn: Int
        public let failure: Kind
        /// How many requests in a row fail.
        public let count: Int

        public init(turn: Int, failure: Kind, count: Int = 1) {
            self.turn = turn
            self.failure = failure
            self.count = count
        }
    }

    public enum Strategy: String, Codable, Sendable, CaseIterable, Comparable {
        /// As the app ships: privacy checks, the classifier and rules, retries and fallback.
        case router
        /// Every turn forced on-device. Long chats answer from their most recent turns.
        case onDevice
        /// Every turn forced to the cloud model, private ones included: the quality ceiling.
        case claude

        public var displayName: String {
            switch self {
            case .router: "Router"
            case .onDevice: "Always on-device"
            case .claude: "Always Claude"
            }
        }

        /// The route this strategy forces, or nil for the router.
        public var forcedRoute: Route? {
            switch self {
            case .router: nil
            case .onDevice: .onDevice
            case .claude: .cloud
            }
        }

        public static func < (lhs: Strategy, rhs: Strategy) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// The judge's grade for one turn.
    public struct Grade: Codable, Sendable, Equatable {
        public let passes: Bool
        /// 1 (wrong or useless) to 5 (excellent).
        public let score: Int
        public let rationale: String
        public let cost: Double?

        public init(passes: Bool, score: Int, rationale: String, cost: Double?) {
            self.passes = passes
            self.score = score
            self.rationale = rationale
            self.cost = cost
        }

        var isJudgeError: Bool { rationale.hasPrefix(QualityBenchmarkRunner.judgeErrorPrefix) }
    }

    /// One turn of one conversation under one strategy.
    public struct TurnResult: Codable, Sendable {
        public let index: Int
        /// The route that answered, or the last one tried.
        public let route: Route?
        public let reason: String?
        public let text: String
        /// Why the turn wasn't answered, or a note such as a cut-off reply.
        public let failure: String?
        /// Every step, failed attempts included.
        public let steps: [StepMetrics]
        /// Why the privacy guard kept this turn private, or nil.
        public let privacyReason: String?
        /// The router moved up because the chat was too long for a smaller model.
        public let movedUp: Bool
        /// Faults that fired on this turn.
        public let faultsFired: Int
        public let grade: Grade?

        public init(index: Int, route: Route?, reason: String?, text: String, failure: String?, steps: [StepMetrics],
                    privacyReason: String?, movedUp: Bool, faultsFired: Int, grade: Grade?) {
            self.index = index
            self.route = route
            self.reason = reason
            self.text = text
            self.failure = failure
            self.steps = steps
            self.privacyReason = privacyReason
            self.movedUp = movedUp
            self.faultsFired = faultsFired
            self.grade = grade
        }

        /// Answered and graded as passing. Unanswered turns fail.
        public var passes: Bool { grade?.passes ?? false }
        public var isAnswered: Bool { !text.isEmpty }
        public var cost: Double { steps.compactMap(\.estimatedCost).reduce(0, +) }
        public var latency: TimeInterval { steps.map(\.totalLatency).reduce(0, +) }
        /// Steps after the first: retries, escalations and fallbacks.
        public var extraSteps: Int { max(steps.count - 1, 0) }
        /// The answering model saw only the most recent turns.
        public var leftOutEarlierTurns: Bool { steps.last?.leftOutEarlierTurns ?? false }
    }

    /// One conversation under one strategy.
    public struct ConversationRun: Codable, Sendable, Identifiable {
        public let conversationID: String
        public let strategy: Strategy
        public let turns: [TurnResult]
        /// Secrets found in requests to the cloud model. Must be empty for the router.
        public let leaks: [String]
        /// Requests the cloud model received.
        public let cloudRequests: Int

        public init(conversationID: String, strategy: Strategy, turns: [TurnResult], leaks: [String], cloudRequests: Int) {
            self.conversationID = conversationID
            self.strategy = strategy
            self.turns = turns
            self.leaks = leaks
            self.cloudRequests = cloudRequests
        }

        public var id: String { "\(conversationID)/\(strategy.rawValue)" }
        public var cost: Double { turns.map(\.cost).reduce(0, +) }
        public var judgeCost: Double { turns.compactMap { $0.grade?.cost }.reduce(0, +) }
        public var allPassed: Bool { !turns.isEmpty && turns.allSatisfy(\.passes) }
    }

    /// A whole run, saved as JSON.
    public struct RunResult: Codable, Sendable {
        public var device: String
        public var classifier: String
        public var judgeModelID: String
        public var cloudModelID: String
        public var startedAt: Date
        /// Routes the router could use, e.g. without Apple Cloud until the entitlement arrives.
        public var availableRoutes: [Route]
        /// The on-device model's context window in tokens: 4,096 on a Mac's AFM 3 Core, 8,192
        /// on an iPhone 17 Pro Max's Core Advanced. Long chats only test trimming if they outgrow it.
        public var onDeviceContextSize: Int?
        public var runs: [ConversationRun]
        /// Answers plus judging, in USD.
        public var spent: Double
        public var stoppedAtSpendCap: Bool

        public init(device: String, classifier: String, judgeModelID: String, cloudModelID: String,
                    startedAt: Date, availableRoutes: [Route]) {
            self.device = device
            self.classifier = classifier
            self.judgeModelID = judgeModelID
            self.cloudModelID = cloudModelID
            self.startedAt = startedAt
            self.availableRoutes = availableRoutes
            self.runs = []
            self.spent = 0
            self.stoppedAtSpendCap = false
        }

        public func run(_ conversationID: String, _ strategy: Strategy) -> ConversationRun? {
            runs.first { $0.conversationID == conversationID && $0.strategy == strategy }
        }

        public static func load(_ data: Data) throws -> RunResult {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RunResult.self, from: data)
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }
    }
}
