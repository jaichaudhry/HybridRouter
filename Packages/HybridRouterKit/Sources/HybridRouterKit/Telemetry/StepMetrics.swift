import Foundation

/// What one model step cost and how fast it ran, shown in the MetricsSheet.
public struct StepMetrics: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var route: Route
    public var modelID: String
    public var reason: String
    public var source: String
    /// Seconds from sending the prompt to the first streamed text, if any text arrived.
    public var timeToFirstToken: TimeInterval?
    public var totalLatency: TimeInterval
    public var usage: TokenUsage
    public var estimatedCost: Double?
    public var escalationCause: String?
    /// How long the on-device classifier took to pick this route, if it ran.
    public var classifierLatency: TimeInterval?
    /// Why this attempt failed, if it did (the turn may have escalated after it).
    public var failure: String?
    /// The route was served by a stand-in model, so speed and cost aren't the real route's.
    public var isSimulated = false

    public init(
        id: UUID = UUID(),
        decision: RouteDecision,
        modelID: String,
        timeToFirstToken: TimeInterval?,
        totalLatency: TimeInterval,
        usage: TokenUsage,
        estimatedCost: Double?,
        escalationCause: String? = nil,
        classifierLatency: TimeInterval? = nil
    ) {
        self.id = id
        self.route = decision.route
        self.modelID = modelID
        self.reason = decision.reason
        self.source = decision.source.rawValue
        self.timeToFirstToken = timeToFirstToken
        self.totalLatency = totalLatency
        self.usage = usage
        self.estimatedCost = estimatedCost
        self.escalationCause = escalationCause
        self.classifierLatency = classifierLatency
    }

    /// Output tokens per second.
    ///
    /// Measured from the first visible token, except when reasoning isn't reported separately
    /// (Claude): then output includes thinking that happened before the first visible token,
    /// so the whole turn is used.
    public var tokensPerSecond: Double? {
        let start = usage.reasoning == nil ? 0 : (timeToFirstToken ?? 0)
        let streaming = totalLatency - start
        guard usage.output > 0, streaming > 0 else { return nil }
        return Double(usage.output) / streaming
    }
}

/// Route mix and cost for a whole session, including what it would have cost on Claude alone.
///
/// The all-Claude figure prices each step's reported tokens at Claude rates. Tokenizers differ
/// between models, so it's an estimate.
public struct SessionSummary: Equatable, Sendable {
    public var stepCount: Int
    public var routeShare: [Route: Double]
    public var totalCost: Double
    public var allClaudeCost: Double

    public var saved: Double { max(allClaudeCost - totalCost, 0) }

    public init(steps: [StepMetrics], costTable: CostTable, claudeModelID: String) {
        stepCount = steps.count
        var counts: [Route: Int] = [:]
        for step in steps { counts[step.route, default: 0] += 1 }
        routeShare = counts.mapValues { Double($0) / Double(max(steps.count, 1)) }
        totalCost = steps.reduce(0) { $0 + ($1.estimatedCost ?? 0) }
        allClaudeCost = steps.reduce(0) { $0 + (costTable.cost(of: $1.usage, modelID: claudeModelID) ?? 0) }
    }
}
