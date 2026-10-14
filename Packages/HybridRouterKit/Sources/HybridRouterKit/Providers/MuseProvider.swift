import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// Meta's Muse Wonder, serving the cloud route in place of Claude.
///
/// Meta's Model API has an Anthropic Messages-compatible endpoint, so this reuses
/// ClaudeForFoundationModels pointed at it, with Meta's bearer key. Checked against
/// `muse-wonder-1.0` in October 2026: streaming, history, tools and structured output work, and
/// the prompt-caching flag the bridge always sends is accepted. Meta doesn't enforce number
/// ranges in structured output, so a guided `.range` can come back out of range.
///
/// It takes the `.claude` slot of a ``RoutedSession``; the route is the "large cloud model" tier.
public struct MuseProvider: ModelProvider {
    public static let baseURL = URL(string: "https://api.meta.ai")!
    static let wonder = ClaudeModel(id: "muse-wonder-1.0", capabilities: .init(
        effortLevels: [.low, .medium, .high],
        adaptiveThinking: true,
        structuredOutput: true,
        imageInput: true
    ))

    public let route = Route.claude
    private let apiKey: String?
    private let configuredContextSize: Int
    private let museModel: ClaudeLanguageModel

    /// - Parameters:
    ///   - apiKey: a Meta Model API key; nil or empty reports the route unavailable.
    ///   - contextSize: Meta lists a 1M-token window for Muse Wonder.
    public init(apiKey: String?, contextSize: Int = 1_000_000) {
        self.apiKey = apiKey
        self.configuredContextSize = contextSize
        // Muse always reasons first, and long reasoning can outlast the bridge's 60-second default.
        self.museModel = ClaudeLanguageModel(
            name: Self.wonder,
            auth: .proxied(headers: ["Authorization": "Bearer \(apiKey ?? "")"]),
            baseURL: Self.baseURL,
            timeout: 180
        )
    }

    public var modelID: String { Self.wonder.id }

    /// The same cap as Claude, so a reply that reaches it is reported as cut off. Includes reasoning.
    public var maximumResponseTokens: Int? { 16_000 }

    public var model: any LanguageModel { museModel }

    public var availability: ProviderAvailability {
        (apiKey ?? "").isEmpty ? .unavailable(reason: "Muse Wonder not configured") : .available
    }

    public func contextSize() async -> Int? {
        configuredContextSize
    }
}
