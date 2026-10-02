import FoundationModels

/// Estimates how many tokens a turn needs, for the context-fit rule.
public protocol TokenEstimator: Sendable {
    func estimate(history: [Transcript.Entry], prompt: String) async -> Int
}

/// Counts with the on-device tokenizer, the only token-counting API Foundation Models has
/// (API_NOTES §4). Apple Cloud and Claude tokenize differently, so routing applies a margin.
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
        let characters = history.reduce(prompt.count) { $0 + String(describing: $1).count }
        return characters / 3 + reservedOutput
    }
}
