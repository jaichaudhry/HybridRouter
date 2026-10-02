import Foundation

/// Token counts for one step, as reported by the model.
public struct TokenUsage: Codable, Hashable, Sendable {
    /// All input tokens, including cached ones.
    public var input: Int
    public var cachedInput: Int
    public var output: Int
    /// Nil when the model doesn't report reasoning separately (Claude bills thinking as output).
    public var reasoning: Int?

    public init(input: Int, cachedInput: Int, output: Int, reasoning: Int?) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoning = reasoning
    }
}

/// Per-model prices loaded from `prices.json`, never hardcoded (SPEC §9).
public struct CostTable: Codable, Equatable, Sendable {
    public struct Price: Codable, Equatable, Sendable {
        /// USD per million tokens.
        public var input: Double
        public var cachedInput: Double
        public var output: Double

        public init(input: Double, cachedInput: Double, output: Double) {
            self.input = input
            self.cachedInput = cachedInput
            self.output = output
        }
    }

    /// When the prices were checked, and where they came from.
    public var updated: String
    public var source: String
    public var models: [String: Price]

    public init(updated: String, source: String, models: [String: Price]) {
        self.updated = updated
        self.source = source
        self.models = models
    }

    public static func bundled() throws -> CostTable {
        guard let url = Bundle.module.url(forResource: "prices", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CostTable.self, from: Data(contentsOf: url))
    }

    /// Estimated cost in USD, or nil if the model has no price entry.
    public func cost(of usage: TokenUsage, modelID: String) -> Double? {
        guard let price = models[modelID] else { return nil }
        let uncached = max(usage.input - usage.cachedInput, 0)
        let dollars = Double(uncached) * price.input
            + Double(usage.cachedInput) * price.cachedInput
            + Double(usage.output) * price.output
        return dollars / 1_000_000
    }
}
