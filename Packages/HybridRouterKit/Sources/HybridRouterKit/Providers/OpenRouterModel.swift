import ClaudeForFoundationModels
import Foundation

/// A model on OpenRouter, as its public catalog describes it: enough to route to it, check that
/// a chat fits, and price a reply.
public struct OpenRouterModel: Codable, Equatable, Sendable, Identifiable {
    /// OpenRouter's ID, e.g. "openai/gpt-5".
    public var id: String
    /// The catalog name, e.g. "OpenAI: GPT-5".
    public var name: String
    public var contextLength: Int
    /// USD per million tokens.
    public var price: CostTable.Price
    public var acceptsImages: Bool
    /// Constrained JSON output, for guided generation.
    public var structuredOutput: Bool

    public init(id: String, name: String, contextLength: Int, price: CostTable.Price,
                acceptsImages: Bool, structuredOutput: Bool) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.price = price
        self.acceptsImages = acceptsImages
        self.structuredOutput = structuredOutput
    }

    /// The name without the vendor prefix, for badges and the route note: "GPT-5", not "OpenAI: GPT-5".
    public var shortName: String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The default: Claude Sonnet through OpenRouter, the model the router was tuned with.
    /// Prices as listed by OpenRouter in October 2026.
    public static let claudeSonnet = OpenRouterModel(
        id: "anthropic/claude-sonnet-5.5",
        name: "Anthropic: Claude Sonnet 5.5",
        contextLength: 1_000_000,
        price: .init(input: 2, cachedInput: 0.1, output: 10),
        acceptsImages: true,
        structuredOutput: true
    )

    /// What the bridge may send: no thinking, effort or sampling settings, which models outside
    /// Anthropic's don't all accept.
    var bridgeModel: ClaudeModel {
        ClaudeModel(id: id, capabilities: .init(structuredOutput: structuredOutput, imageInput: acceptsImages))
    }
}

/// OpenRouter's public model list (`GET /api/v1/models`, no key needed), narrowed to models
/// that reply in text.
public struct OpenRouterCatalog: Codable, Sendable {
    public static let url = URL(string: "https://openrouter.ai/api/v1/models")!

    public var models: [OpenRouterModel]

    public init(models: [OpenRouterModel]) {
        self.models = models
    }

    /// Parses the catalog response. Models that don't take and return text are left out.
    public init(catalogJSON data: Data) throws {
        let response = try JSONDecoder().decode(Response.self, from: data)
        models = response.data.compactMap(\.model).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Downloads the current catalog.
    public static func fetch(session: URLSession = .shared) async throws -> OpenRouterCatalog {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try OpenRouterCatalog(catalogJSON: data)
    }

    public func model(id: String) -> OpenRouterModel? {
        models.first { $0.id == id }
    }

    /// Models whose name or ID contains every word of `query`, ignoring case.
    public func search(_ query: String) -> [OpenRouterModel] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return models }
        return models.filter { model in
            words.allSatisfy { model.name.localizedCaseInsensitiveContains($0) || model.id.localizedCaseInsensitiveContains($0) }
        }
    }

    private struct Response: Decodable {
        var data: [Entry]
    }

    private struct Entry: Decodable {
        struct Architecture: Decodable {
            var input_modalities: [String]?
            var output_modalities: [String]?
        }
        struct Pricing: Decodable {
            var prompt: String?
            var completion: String?
            var input_cache_read: String?
        }
        var id: String
        var name: String?
        var context_length: Int?
        var architecture: Architecture?
        var pricing: Pricing?
        var supported_parameters: [String]?

        var model: OpenRouterModel? {
            let inputs = architecture?.input_modalities ?? ["text"]
            let outputs = architecture?.output_modalities ?? ["text"]
            // ":batch" variants only run through the asynchronous Batch API.
            guard !id.hasSuffix(":batch"), inputs.contains("text"), outputs == ["text"], let contextLength = context_length, contextLength > 0,
                  let input = Self.perMillion(pricing?.prompt), let output = Self.perMillion(pricing?.completion),
                  input >= 0, output >= 0 else { return nil }
            return OpenRouterModel(
                id: id,
                name: name ?? id,
                contextLength: contextLength,
                price: .init(input: input, cachedInput: Self.perMillion(pricing?.input_cache_read) ?? input, output: output),
                acceptsImages: inputs.contains("image"),
                structuredOutput: supported_parameters?.contains("structured_outputs") ?? false
            )
        }

        /// The catalog lists USD per token as a string; -1 marks a variable price.
        static func perMillion(_ perToken: String?) -> Double? {
            perToken.flatMap(Double.init).map { $0 * 1_000_000 }
        }
    }
}
