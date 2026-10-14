import Foundation

/// Measures routing on answer quality, not label agreement: each prompt is answered on every
/// route, a judge grades the answers, and the router is scored against the cheapest route whose
/// answer passed. Shared by the Mac evals and the in-app Developer screen.
public enum QualityBenchmark {
    /// A prompt to answer on every route. Self-contained: documents are pasted inline.
    public struct Case: Codable, Sendable, Identifiable, Hashable {
        public let id: Int
        /// "tuning" prompts were used while tuning the classifier; "heldout" prompts weren't, and
        /// supply the headline numbers.
        public let split: String
        public let group: String
        public let task: String
        /// The intended difficulty, for analysis only. The router isn't scored against it.
        public let difficulty: String
        public let prompt: String
        public let previousPrompt: String?
        /// What a correct answer must contain, for the judge. Nil for open-ended prompts.
        public let criteria: String?

        public init(
            id: Int, split: String, group: String, task: String, difficulty: String,
            prompt: String, previousPrompt: String? = nil, criteria: String? = nil
        ) {
            self.id = id
            self.split = split
            self.group = group
            self.task = task
            self.difficulty = difficulty
            self.prompt = prompt
            self.previousPrompt = previousPrompt
            self.criteria = criteria
        }
    }

    /// Where an answer comes from. The first three are the routes the router chooses between,
    /// cheapest first; `claudeDeep` (Opus) is the quality ceiling and `museWonder` (Meta) a
    /// comparison, never routing choices.
    public enum Column: String, Codable, Sendable, CaseIterable, Comparable {
        case onDevice, appleCloud, claude, claudeDeep, museWonder

        /// The route that serves this column.
        public var route: Route {
            switch self {
            case .onDevice: .onDevice
            case .appleCloud: .appleCloud
            case .claude, .claudeDeep, .museWonder: .claude
            }
        }

        /// The routing rungs, cheapest first.
        public static let rungs: [Column] = [.onDevice, .appleCloud, .claude]

        /// The rung the router's route corresponds to.
        public init(rung route: Route) {
            switch route {
            case .onDevice: self = .onDevice
            case .appleCloud: self = .appleCloud
            case .claude: self = .claude
            }
        }

        public var displayName: String {
            switch self {
            case .onDevice: "On-device"
            case .appleCloud: "Apple Cloud"
            case .claude: "Claude Sonnet"
            case .claudeDeep: "Claude Opus"
            case .museWonder: "Muse Wonder"
            }
        }

        public static func < (lhs: Column, rhs: Column) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// One column's answer to one prompt.
    public struct Answer: Codable, Sendable {
        public let column: Column
        public let modelID: String
        public let text: String
        public let metrics: StepMetrics?
        /// Why the column didn't answer. A failed answer counts as failing, unjudged.
        public let failure: String?

        public init(column: Column, modelID: String, text: String, metrics: StepMetrics?, failure: String?) {
            self.column = column
            self.modelID = modelID
            self.text = text
            self.metrics = metrics
            self.failure = failure
        }

        public var cost: Double { metrics?.estimatedCost ?? 0 }
    }

    /// The judge's grade for one answer.
    public struct Judgment: Codable, Sendable {
        public let column: Column
        public let passes: Bool
        /// 1 (wrong or useless) to 5 (excellent).
        public let score: Int
        public let rationale: String
        /// What judging this answer cost, if known. Not part of any strategy's cost.
        public let cost: Double?

        public init(column: Column, passes: Bool, score: Int, rationale: String, cost: Double?) {
            self.column = column
            self.passes = passes
            self.score = score
            self.rationale = rationale
            self.cost = cost
        }
    }

    /// Everything measured for one prompt.
    public struct CaseResult: Codable, Sendable, Identifiable {
        public let `case`: Case
        /// The route the router picked, with the app's real availability. Nil if it blocked.
        public let routerRoute: Route?
        public let routerReason: String?
        public let routerLatency: TimeInterval?
        public let answers: [Answer]
        public let judgments: [Judgment]

        public init(case: Case, routerRoute: Route?, routerReason: String?, routerLatency: TimeInterval?, answers: [Answer], judgments: [Judgment]) {
            self.case = `case`
            self.routerRoute = routerRoute
            self.routerReason = routerReason
            self.routerLatency = routerLatency
            self.answers = answers
            self.judgments = judgments
        }

        public var id: Int { self.case.id }

        public func answer(_ column: Column) -> Answer? { answers.first { $0.column == column } }
        public func judgment(_ column: Column) -> Judgment? { judgments.first { $0.column == column } }

        /// Whether a column's answer passed. Failed and unjudged answers don't pass.
        public func passes(_ column: Column) -> Bool { judgment(column)?.passes ?? false }
        public func score(_ column: Column) -> Int { judgment(column)?.score ?? 1 }

        /// The router's choice had Apple Cloud been available. The classifier's label doesn't
        /// depend on availability, and a turn it sent to Apple Cloud moves up only because
        /// Apple Cloud is missing ("… (Apple Cloud unavailable)"), so those turns, and failed
        /// classifications (which fall back to Apple Cloud), move back down. Others are unchanged.
        public func routedWithAppleCloud() -> CaseResult {
            guard let reason = routerReason, routerRoute != .appleCloud else { return self }
            let suffix = " (\(Route.appleCloud.displayName) unavailable)"
            let newReason: String
            if reason.hasSuffix(suffix) {
                newReason = String(reason.dropLast(suffix.count))
            } else if reason.hasPrefix("Couldn't classify") {
                newReason = reason
            } else {
                return self
            }
            return CaseResult(case: self.case, routerRoute: .appleCloud, routerReason: newReason,
                              routerLatency: routerLatency, answers: answers, judgments: judgments)
        }
    }

    /// A whole run, saved as JSON so runs can be compared and re-reported later.
    public struct RunResult: Codable, Sendable {
        public var device: String
        public var classifier: String
        public var judgeModelID: String
        public var startedAt: Date
        /// Columns that answered. Others are listed in `unmeasured` with the reason.
        public var columns: [Column]
        public var unmeasured: [String: String]
        public var cases: [CaseResult]
        /// Answers plus judging, in USD.
        public var spent: Double
        public var stoppedAtSpendCap: Bool
        /// Set when a route's provider reported its rate limit, e.g. Apple Cloud's daily
        /// allowance. Prompts it couldn't answer stay pending, so a later run picks them up.
        public var stoppedAtRateLimit: Bool?
        /// How the router's choices were derived, when not measured directly in this run.
        public var routerNote: String?

        public init(device: String, classifier: String, judgeModelID: String, startedAt: Date, columns: [Column], unmeasured: [String: String]) {
            self.device = device
            self.classifier = classifier
            self.judgeModelID = judgeModelID
            self.startedAt = startedAt
            self.columns = columns
            self.unmeasured = unmeasured
            self.cases = []
            self.spent = 0
            self.stoppedAtSpendCap = false
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

    /// Instructions every column answers with, so runs on a Mac and an iPhone are comparable.
    public static let answerInstructions = "You are a helpful assistant. Answer clearly and concisely. Use Markdown for lists and emphasis."

    public static func load(_ data: Data) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: data)
    }
}
