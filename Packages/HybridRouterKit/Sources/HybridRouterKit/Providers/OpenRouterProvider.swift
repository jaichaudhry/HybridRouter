import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// A model on OpenRouter serving the cloud route, with the person's own OpenRouter key: requests
/// are billed to their OpenRouter credits.
///
/// OpenRouter serves an Anthropic Messages-compatible endpoint for every model, so this reuses
/// ClaudeForFoundationModels pointed at it, like ``MuseProvider``. Only the features the catalog
/// lists for the model are sent: no thinking or effort settings, images only for models that
/// take them, structured output only where it's supported.
public struct OpenRouterProvider: ModelProvider {
    public static let baseURL = URL(string: "https://openrouter.ai/api")!
    /// Sent as `HTTP-Referer` so OpenRouter can attribute requests to the app.
    public static let attributionURL = "https://github.com/jaichaudhry/HybridRouter"

    public let route = Route.cloud
    public let openRouterModel: OpenRouterModel
    private let apiKey: String?
    private let bridged: ClaudeLanguageModel

    /// - Parameters:
    ///   - apiKey: an OpenRouter API key; nil or empty reports the route unavailable.
    ///   - model: the model to use, from ``OpenRouterCatalog`` or ``OpenRouterModel/claudeSonnet``.
    ///   - appName: shown in the person's OpenRouter activity.
    public init(apiKey: String?, model: OpenRouterModel = .claudeSonnet, appName: String = "HybridRouter") {
        self.apiKey = apiKey
        self.openRouterModel = model
        self.bridged = ClaudeLanguageModel(
            name: model.bridgeModel,
            auth: .proxied(headers: [
                "Authorization": "Bearer \(apiKey ?? "")",
                "HTTP-Referer": Self.attributionURL,
                "X-Title": appName,
            ]),
            baseURL: Self.baseURL,
            timeout: 180
        )
    }

    public var modelID: String { openRouterModel.id }

    public var displayName: String { openRouterModel.shortName }

    /// The same cap as Claude, so a reply that reaches it is reported as cut off.
    public var maximumResponseTokens: Int? { 16_000 }

    public var model: any LanguageModel { bridged }

    public var availability: ProviderAvailability {
        (apiKey ?? "").isEmpty ? .unavailable(reason: "OpenRouter not configured") : .available
    }

    public func contextSize() async -> Int? {
        openRouterModel.contextLength
    }

    /// From OpenRouter's catalog, so any model is priced.
    public var price: CostTable.Price? { openRouterModel.price }
}
