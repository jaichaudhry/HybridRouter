import Foundation
import Testing
@testable import HybridRouterKit

struct TelemetryTests {
    private let table = CostTable(
        updated: "2026-10-02",
        source: "test",
        models: [
            "apple-on-device": .init(input: 0, cachedInput: 0, output: 0),
            "claude-sonnet-5-5": .init(input: 2, cachedInput: 0.2, output: 10),
        ]
    )

    @Test func bundledTableLoadsWithDateAndSource() throws {
        let bundled = try CostTable.bundled()
        #expect(bundled.updated == "2026-10-02")
        #expect(bundled.source.hasPrefix("https://"))
        #expect(bundled.models["claude-sonnet-5-5"]?.output == 10)
        #expect(bundled.models["apple-on-device"]?.input == 0)
    }

    @Test func cachedTokensArePricedSeparately() {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 400_000, output: 100_000, reasoning: nil)
        // 600k uncached at $2 + 400k cached at $0.20 + 100k output at $10
        let cost = table.cost(of: usage, modelID: "claude-sonnet-5-5")
        #expect(abs((cost ?? 0) - 2.28) < 0.000_001)
    }

    @Test func unknownModelHasNoCost() {
        let usage = TokenUsage(input: 10, cachedInput: 0, output: 10, reasoning: nil)
        #expect(table.cost(of: usage, modelID: "mystery") == nil)
    }

    @Test func tokensPerSecondIsMeasuredFromFirstToken() {
        let metrics = StepMetrics(
            decision: .forced(.onDevice),
            modelID: "apple-on-device",
            timeToFirstToken: 0.5,
            totalLatency: 2.5,
            usage: TokenUsage(input: 20, cachedInput: 0, output: 100, reasoning: 0),
            estimatedCost: 0
        )
        #expect(metrics.tokensPerSecond == 50)
    }

    @Test func tokensPerSecondIncludesThinkingTimeWhenReasoningIsUnreported() {
        // Claude: 2,000 thinking + 200 text tokens; 20 s thinking, then 2 s of text.
        let metrics = StepMetrics(
            decision: .forced(.cloud),
            modelID: "claude-sonnet-5-5",
            timeToFirstToken: 20,
            totalLatency: 22,
            usage: TokenUsage(input: 20, cachedInput: 0, output: 2_200, reasoning: nil),
            estimatedCost: nil
        )
        #expect(metrics.tokensPerSecond == 100)
    }

    @Test func summaryReportsRouteMixAndSavings() {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 0, output: 0, reasoning: nil)
        let steps = [
            StepMetrics(decision: .forced(.onDevice), modelID: "apple-on-device", timeToFirstToken: nil,
                        totalLatency: 1, usage: usage, estimatedCost: 0),
            StepMetrics(decision: .forced(.cloud), modelID: "claude-sonnet-5-5", timeToFirstToken: nil,
                        totalLatency: 1, usage: usage, estimatedCost: 2),
        ]
        let summary = SessionSummary(steps: steps, costTable: table, cloudModelID: "claude-sonnet-5-5")
        #expect(summary.routeShare[.onDevice] == 0.5)
        #expect(summary.routeShare[.cloud] == 0.5)
        #expect(summary.totalCost == 2)
        #expect(summary.allCloudCost == 4)
        #expect(summary.saved == 2)
        #expect(summary.unpricedSteps == 0)
    }

    @Test func summaryCountsCloudStepsWithoutAPrice() {
        let usage = TokenUsage(input: 100, cachedInput: 0, output: 10, reasoning: nil)
        let unpriced = StepMetrics(decision: .forced(.cloud), modelID: "gemini-3", timeToFirstToken: nil,
                                   totalLatency: 1, usage: usage, estimatedCost: nil)
        let free = StepMetrics(decision: .forced(.onDevice), modelID: "apple-on-device", timeToFirstToken: nil,
                               totalLatency: 1, usage: usage, estimatedCost: nil)
        #expect(SessionSummary(steps: [unpriced, free], costTable: table, cloudModelID: "claude-sonnet-5-5").unpricedSteps == 1)
    }

    @Test func metricsRoundTripAsJSON() throws {
        let metrics = StepMetrics(
            decision: .forced(.cloud), modelID: "claude-sonnet-5-5", timeToFirstToken: 0.3,
            totalLatency: 1.2, usage: TokenUsage(input: 5, cachedInput: 1, output: 7, reasoning: nil),
            estimatedCost: 0.0001, escalationCause: "timeout"
        )
        let decoded = try JSONDecoder().decode(StepMetrics.self, from: JSONEncoder().encode(metrics))
        #expect(decoded == metrics)
    }
}
