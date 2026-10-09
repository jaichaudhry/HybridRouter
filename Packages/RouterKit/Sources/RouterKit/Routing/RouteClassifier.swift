import FoundationModels

/// Classifies a turn's complexity and task (SPEC §6 Layer B).
public protocol RouteClassifier: Sendable {
    /// - Parameter previous: the previous user message, for short follow-ups; nil otherwise.
    func classify(_ prompt: String, previous: String?) async throws -> RouteClassification
}

extension RouteClassifier {
    public func classify(_ prompt: String) async throws -> RouteClassification {
        try await classify(prompt, previous: nil)
    }
}

/// Classifies with the on-device model, using a fresh, short session per turn so it stays fast.
public struct OnDeviceClassifier: RouteClassifier {
    /// Instructions for the classifier. Different on-device model variants read the same
    /// instructions differently, so each set is tuned on the variant it's used with.
    public struct InstructionSet: Sendable, Hashable, Identifiable {
        public let id: String
        public let text: String

        /// Tuned on AFM 3 Core (M1 Max, macOS 27): 48/50 on Evals/classifier_benchmark.json.
        /// Longer rule lists and a "choose the higher level when unsure" line scored lower.
        public static let core = InstructionSet(id: "core", text: """
            Label the user's message for routing to a small, medium or large model.
            simple: chit-chat, thanks, brainstorm lists, quick facts, definitions, how everyday things work, rewriting or shortening text.
            moderate: building a detailed plan or itinerary, summarizing long text, structured documents.
            complex: judging whether something is realistic, trade-offs, what to cut or push back on, critique, advice under constraints, code.
            Examples:
            "Give me 10 dinner ideas" -> simple, chat
            "Make a grocery checklist for a camping weekend" -> simple, chat
            "What does escrow mean?" -> simple, chat
            "Turn this into a short email" -> simple, rewrite
            "Make a 5-day Rome itinerary for a couple" -> moderate, plan
            "List the main points of this article" -> moderate, summarize
            "Is this budget realistic? What would you change?" -> complex, reason
            "Which offer should I take and why?" -> complex, reason
            """)

        /// Candidate for AFM 3 Core Advanced, which labeled 6 of 50 benchmark prompts complex that
        /// were reviewed as moderate (iPhone 17 Pro Max, iOS 27.0.1: 42/50 with `core`).
        /// Reserves "complex" for judgment explicitly.
        public static let advancedA = InstructionSet(id: "advanced-a", text: core.text + """

            Most messages are simple or moderate. Use complex only when the user asks you to judge, compare options or decide something for them.
            """)

        /// Like `advancedA`, plus examples of writing, explaining and extracting that aren't complex.
        public static let advancedB = InstructionSet(id: "advanced-b", text: advancedA.text + """

            More examples:
            "Write a thank-you note to our host" -> simple, rewrite
            "Plan a 3-day Paris trip for friends on a budget" -> moderate, plan
            "Explain how a mortgage works" -> moderate, chat
            "Pull the key dates out of this lease" -> moderate, extract
            """)

        public static let all: [InstructionSet] = [.core, .advancedA, .advancedB]

        /// The set tuned for a model variant. Variants without their own tuning use `core`.
        public static func tuned(for variant: SystemLanguageModel.Variant) -> InstructionSet {
            .core
        }
    }

    /// The set in use by default, for code that only needs the text.
    static var instructions: String { InstructionSet.core.text }

    /// Short messages get the previous one for context ("Now do the same for Osaka").
    /// Longer ones stand alone, which keeps the prompt, and the latency, small.
    static let contextWordLimit = 8

    /// The opening of a long message (e.g. one with a pasted document) is enough to label it,
    /// and keeps the classifier within the on-device context window.
    static let promptCharacterLimit = 600

    static func classifierPrompt(_ prompt: String, previous: String?) -> String {
        let message = String(prompt.prefix(promptCharacterLimit))
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        guard let previous, words <= contextWordLimit else { return message }
        return "Previous message: \(previous.prefix(240))\nMessage to label: \(message)"
    }

    private let model: SystemLanguageModel
    public let instructionSet: InstructionSet

    /// - Parameter instructionSet: defaults to the set tuned for the model's variant.
    public init(model: SystemLanguageModel = .default, instructionSet: InstructionSet? = nil) {
        self.model = model
        self.instructionSet = instructionSet ?? InstructionSet.tuned(for: model.variant)
    }

    public func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
        let session = LanguageModelSession(model: model, instructions: instructionSet.text)
        let response = try await session.respond(
            to: Self.classifierPrompt(prompt, previous: previous),
            generating: RouteClassification.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content
    }
}
