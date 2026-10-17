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
    /// When the model saw only recent turns: how many earlier turns it saw…
    public var earlierTurnsSeen: Int?
    /// …out of how many there were.
    public var earlierTurns: Int?

    /// True when the model answered without seeing the whole conversation.
    public var leftOutEarlierTurns: Bool {
        guard let earlierTurnsSeen, let earlierTurns else { return false }
        return earlierTurnsSeen < earlierTurns
    }

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

/// Route mix and cost for a whole session, including what it would have cost on the cloud
/// model alone.
///
/// The all-cloud figure prices each step's reported tokens at the cloud model's rates.
/// Tokenizers differ between models, so it's an estimate.
public struct SessionSummary: Equatable, Sendable {
    public var stepCount: Int
    public var routeShare: [Route: Double]
    public var totalCost: Double
    public var allCloudCost: Double
    /// Paid steps whose model isn't in the price table, so they're missing from `totalCost`.
    public var unpricedSteps: Int

    public var saved: Double { max(allCloudCost - totalCost, 0) }

    @available(*, deprecated, renamed: "allCloudCost")
    public var allClaudeCost: Double { allCloudCost }

    public init(steps: [StepMetrics], costTable: CostTable, cloudModelID: String) {
        stepCount = steps.count
        var counts: [Route: Int] = [:]
        for step in steps { counts[step.route, default: 0] += 1 }
        routeShare = counts.mapValues { Double($0) / Double(max(steps.count, 1)) }
        totalCost = steps.reduce(0) { $0 + ($1.estimatedCost ?? 0) }
        allCloudCost = steps.reduce(0) { $0 + (costTable.cost(of: $1.usage, modelID: cloudModelID) ?? 0) }
        // Apple's routes are free and aren't listed; a cloud step without a price is a gap.
        unpricedSteps = steps.filter { $0.route == .cloud && $0.estimatedCost == nil && !$0.isSimulated }.count
    }

    @available(*, deprecated, renamed: "init(steps:costTable:cloudModelID:)")
    public init(steps: [StepMetrics], costTable: CostTable, claudeModelID: String) {
        self.init(steps: steps, costTable: costTable, cloudModelID: claudeModelID)
    }
}
