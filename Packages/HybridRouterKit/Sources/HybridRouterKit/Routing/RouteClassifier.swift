import FoundationModels

/// Classifies a turn's complexity and task.
public protocol RouteClassifier: Sendable {
    /// - Parameters:
    ///   - prompt: the user's message.
    ///   - previous: the previous user message, for short follow-ups; nil otherwise.
    func classify(_ prompt: String, previous: String?) async throws -> RouteClassification

    /// Gets ready for the first real turn, e.g. by loading the model. Optional.
    func prewarm() async
}

extension RouteClassifier {
    public func classify(_ prompt: String) async throws -> RouteClassification {
        try await classify(prompt, previous: nil)
    }

    public func prewarm() async {}
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

        /// AFM 3 Core Advanced labeled more prompts complex than reviewed (iPhone 17 Pro Max,
        /// iOS 27.0.1: 42/50 with `core`). Reserves "complex" for judgment explicitly. 43/50.
        public static let advancedA = InstructionSet(id: "advanced-a", text: core.text + """

            Most messages are simple or moderate. Use complex only when the user asks you to judge, compare options or decide something for them.
            """)

        /// Like `advancedA`, plus examples of writing, explaining and extracting that aren't complex.
        /// Tuned on AFM 3 Core Advanced (iPhone 17 Pro Max, iOS 27.0.1): 46/50, every miss one
        /// level higher, median 628 ms. On AFM 3 Core it scores 46/50, below `core`.
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
            variant == .coreAdvanced3 ? .advancedB : .core
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

    /// Words that point back at the previous message ("do the same for Osaka", "make it shorter").
    static let referenceWords: Set<String> = [
        "that", "this", "it", "its", "those", "these", "them", "same", "again", "instead",
        "also", "too", "more", "other", "another", "previous", "above",
    ]

    static func classifierPrompt(_ prompt: String, previous: String?) -> String {
        let message = String(prompt.prefix(promptCharacterLimit))
        let words = prompt.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        // Only short messages that refer back get the previous one. Otherwise its label bleeds
        // in: on an iPhone 17 Pro Max, "Make a packing list for the kids" after a trade-offs
        // question was classified as complex reasoning.
        guard let previous, words.count <= contextWordLimit, words.contains(where: referenceWords.contains) else {
            return message
        }
        return "Previous message: \(previous.prefix(240))\nMessage to label: \(message)"
    }

    private let model: SystemLanguageModel
    public let instructionSet: InstructionSet

    /// - Parameters:
    ///   - model: the on-device model that does the classifying.
    ///   - instructionSet: defaults to the set tuned for the model's variant.
    public init(model: SystemLanguageModel = .default, instructionSet: InstructionSet? = nil) {
        self.model = model
        self.instructionSet = instructionSet ?? InstructionSet.tuned(for: model.variant)
    }

    /// Classifies a throwaway message so the first real turn doesn't pay for loading the model
    /// and the output schema. On an iPhone 17 Pro Max the first message after launch sat on
    /// "Checking privacy and complexity…" for seconds; later ones take about 0.6 s.
    public func prewarm() async {
        _ = try? await classify("Hi", previous: nil)
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

/// Labels what a turn needs rather than how complex it sounds, then maps that to the
/// complexity the router uses. The complexity labels hardly predict when the on-device model
/// fails (AUROC 0.57 on the development prompts); "needs" does better because it asks about
/// the small model's known weak spots directly. Experimental: compare with Replay first.
public struct NeedsClassifier: RouteClassifier {
    @Generable
    struct Needs {
        @Guide(description: "What the request needs", .anyOf(NeedsClassifier.categories.map(\.label)))
        var needs: String
    }

    /// Each label and the router classification it maps to.
    static let categories: [(label: String, classification: RouteClassification)] = [
        ("general knowledge or writing", RouteClassification(complexity: "simple", task: "chat")),
        ("specific real places, prices, rules or facts", RouteClassification(complexity: "simple", task: "chat")),
        ("long multi-part plan", RouteClassification(complexity: "moderate", task: "plan")),
        ("judgment between options", RouteClassification(complexity: "complex", task: "reason")),
        ("exact arithmetic, counting or dates", RouteClassification(complexity: "complex", task: "reason")),
        ("code", RouteClassification(complexity: "complex", task: "code")),
    ]

    public static let instructionsID = "needs-a"

    static let instructions = """
        Decide what the user's message needs from an assistant. A small on-device assistant is good at \
        everyday explanations, rewriting, summarizing pasted text, extracting from pasted text, short lists \
        and simple code. It makes mistakes with exact arithmetic, counting letters or words, dates and time \
        zones, specific real-world facts (places, prices, laws, schedules), long detailed itineraries, and \
        long or tricky code.
        """

    private let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    public func prewarm() async {
        _ = try? await classify("Hi", previous: nil)
    }

    public func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(
            to: OnDeviceClassifier.classifierPrompt(prompt, previous: previous),
            generating: Needs.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return Self.categories.first { $0.label == response.content.needs }?.classification
            ?? RouteClassification(complexity: "moderate", task: "chat")
    }
}
