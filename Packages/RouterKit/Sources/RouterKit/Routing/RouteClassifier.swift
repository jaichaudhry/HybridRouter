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
    static let instructions = """
        Label the user's message for routing to a small, medium or large model.
        simple: chit-chat, thanks, brainstorm lists, quick facts, rewriting or shortening text.
        moderate: building a detailed plan or itinerary, summarizing long text, structured documents.
        complex: judging whether something is realistic, trade-offs, what to cut or push back on, critique, advice under constraints, code.
        Examples:
        "Give me 10 dinner ideas" -> simple, chat
        "Make a grocery checklist for a camping weekend" -> simple, chat
        "Turn this into a short email" -> simple, rewrite
        "Make a 5-day Rome itinerary for a couple" -> moderate, plan
        "List the main points of this article" -> moderate, summarize
        "Is this budget realistic? What would you change?" -> complex, reason
        "Which offer should I take and why?" -> complex, reason
        """

    /// Short messages get the previous one for context ("Now do the same for Osaka").
    /// Longer ones stand alone, which keeps the prompt, and the latency, small.
    static let contextWordLimit = 8

    static func classifierPrompt(_ prompt: String, previous: String?) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace).count
        guard let previous, words <= contextWordLimit else { return prompt }
        return "Previous message: \(previous.prefix(240))\nMessage to label: \(prompt)"
    }

    private let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    public func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(
            to: Self.classifierPrompt(prompt, previous: previous),
            generating: RouteClassification.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content
    }
}
