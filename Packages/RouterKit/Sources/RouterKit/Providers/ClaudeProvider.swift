import ClaudeForFoundationModels
import FoundationModels

/// Anthropic Claude through ClaudeForFoundationModels.
public struct ClaudeProvider: ModelProvider {
    /// Sonnet for normal complex turns; Opus for the hardest ones (SPEC §13 Q3).
    public enum Tier: String, Sendable, CaseIterable {
        case standard
        case deep

        var claudeModel: ClaudeModel {
            switch self {
            case .standard: .sonnet5_5
            case .deep: .opus5_5
            }
        }
    }

    public let route = Route.claude
    public let tier: Tier
    private let auth: ClaudeAuth
    private let configuredContextSize: Int
    private let claudeModel: ClaudeLanguageModel

    /// - Parameter contextSize: ClaudeForFoundationModels doesn't expose it. Anthropic's pricing
    ///   page lists a 1M-token window for Claude 4.6 and later models.
    public init(auth: ClaudeAuth, tier: Tier = .standard, contextSize: Int = 1_000_000) {
        self.auth = auth
        self.tier = tier
        self.configuredContextSize = contextSize
        // With auth off, an empty key makes any accidental request fail with `missingCredential`.
        self.claudeModel = ClaudeLanguageModel(name: tier.claudeModel, auth: auth.authMode ?? .apiKey(""))
    }

    public var modelID: String { tier.claudeModel.id }

    /// Set explicitly (it's also the bridge's default) so a reply that reaches it can be
    /// reported as cut off: Claude's max_tokens stop doesn't throw. Includes thinking tokens.
    public var maximumResponseTokens: Int? { 16_000 }

    public var model: any LanguageModel { claudeModel }

    public var availability: ProviderAvailability {
        auth.isEnabled ? .available : .unavailable(reason: "Claude not configured")
    }

    public func contextSize() async -> Int? {
        configuredContextSize
    }

    /// Prewarms App Attest so the first Claude turn doesn't wait for attestation.
    public func authenticateIfNeeded() async throws {
        try await claudeModel.authenticateIfNeeded()
    }
}
