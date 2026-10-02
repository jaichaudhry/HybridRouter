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
    private let claudeModel: ClaudeLanguageModel

    public init(auth: ClaudeAuth, tier: Tier = .standard) {
        self.auth = auth
        self.tier = tier
        // With auth off, an empty key makes any accidental request fail with `missingCredential`.
        self.claudeModel = ClaudeLanguageModel(name: tier.claudeModel, auth: auth.authMode ?? .apiKey(""))
    }

    public var modelID: String { tier.claudeModel.id }

    public var model: any LanguageModel { claudeModel }

    public var availability: ProviderAvailability {
        auth.isEnabled ? .available : .unavailable(reason: "Claude not configured")
    }

    /// Prewarms App Attest so the first Claude turn doesn't wait for attestation.
    public func authenticateIfNeeded() async throws {
        try await claudeModel.authenticateIfNeeded()
    }
}
