import FoundationModels

/// Estimates how many tokens a turn needs, for the context-fit rule.
public protocol TokenEstimator: Sendable {
    /// - Parameters:
    ///   - history: the transcript so far.
    ///   - prompt: the new message, preceded by the text every request carries (instructions,
    ///     route note and tool descriptions; see ``RoutedSession/fixedPromptText``).
    func estimate(history: [Transcript.Entry], prompt: String) async -> Int
}

/// Counts with the on-device tokenizer, the only token-counting API Foundation Models has.
/// Apple Cloud and Claude tokenize differently, so routing applies a margin.
public struct OnDeviceTokenEstimator: TokenEstimator {
    /// Tokens kept free for the reply.
    public var reservedOutput: Int
    private let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default, reservedOutput: Int = 1_024) {
        self.model = model
        self.reservedOutput = reservedOutput
    }

    public func estimate(history: [Transcript.Entry], prompt: String) async -> Int {
        do {
            let historyTokens = try await model.tokenCount(for: history)
            let promptTokens = try await model.tokenCount(for: prompt)
            return historyTokens + promptTokens + reservedOutput
        } catch {
            return CharacterTokenEstimator(reservedOutput: reservedOutput).count(history: history, prompt: prompt)
        }
    }
}

/// A conservative estimate (3 characters per token) for when no tokenizer is available.
public struct CharacterTokenEstimator: TokenEstimator {
    public var reservedOutput: Int

    public init(reservedOutput: Int = 1_024) {
        self.reservedOutput = reservedOutput
    }

    public func estimate(history: [Transcript.Entry], prompt: String) async -> Int {
        count(history: history, prompt: prompt)
    }

    func count(history: [Transcript.Entry], prompt: String) -> Int {
        let characters = history.reduce(prompt.count) { $0 + $1.textForCounting.count }
        return characters / 3 + reservedOutput
    }
}

extension Transcript.Entry {
    /// The entry's text, without the debug description's field names and IDs.
    var textForCounting: String {
        let segments: [Transcript.Segment]
        switch self {
        case .prompt(let prompt): segments = prompt.segments
        case .response(let response): segments = response.segments
        case .instructions(let instructions): segments = instructions.segments
        case .toolOutput(let output): segments = output.segments
        case .toolCalls(let calls): return calls.map { "\($0.toolName) \($0.arguments.jsonString)" }.joined(separator: "\n")
        default: return String(describing: self)
        }
        return segments.map { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: String(describing: segment)
            }
        }.joined(separator: "\n")
    }
}
