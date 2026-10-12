import FoundationModels
import HybridRouterKit

/// Reports a fixed token count, to drive the context-fit rule in tests.
public struct FixedTokenEstimator: TokenEstimator {
    public var tokens: Int

    public init(_ tokens: Int) {
        self.tokens = tokens
    }

    public func estimate(history: [Transcript.Entry], prompt: String) async -> Int {
        tokens
    }
}
