import RouterKit

/// A classifier that returns canned classifications by prompt, or fails.
public struct FakeClassifier: RouteClassifier {
    public struct Failure: Error {}

    private let answers: [String: RouteClassification]
    private let fallback: RouteClassification?

    /// - Parameters:
    ///   - answers: classification per exact prompt.
    ///   - fallback: used for other prompts; nil makes them fail.
    public init(_ answers: [String: RouteClassification] = [:], fallback: RouteClassification? = nil) {
        self.answers = answers
        self.fallback = fallback
    }

    /// Always answers with the given complexity.
    public static func always(_ complexity: String, task: String = "chat") -> FakeClassifier {
        FakeClassifier(fallback: RouteClassification(complexity: complexity, task: task))
    }

    public static let failing = FakeClassifier()

    public func classify(_ prompt: String, previous: String?) async throws -> RouteClassification {
        guard let answer = answers[prompt] ?? fallback else { throw Failure() }
        return answer
    }
}
