import Foundation

/// Scores a benchmark run: quality and cost for the router and simple strategies, and how the
/// router's choices compare with the cheapest route that would have been good enough.
public struct QualityReport: Sendable {
    /// One way of choosing a route for every prompt.
    public enum Strategy: String, Sendable, CaseIterable {
        case router
        case alwaysOnDevice
        case alwaysClaude
        case alwaysClaudeDeep
        /// The router's route mix, assigned at random: computed as an exact expectation.
        case randomSameMix
        /// The cheapest route whose answer passed: the best any router could do.
        case oracle

        public var displayName: String {
            switch self {
            case .router: "HybridRouter"
            case .alwaysOnDevice: "Always on-device"
            case .alwaysClaude: "Always Claude Sonnet"
            case .alwaysClaudeDeep: "Always Claude Opus"
            case .randomSameMix: "Random, same mix"
            case .oracle: "Oracle (cheapest good-enough)"
            }
        }
    }

    public struct StrategyResult: Sendable, Equatable {
        public let strategy: Strategy
        /// Share of prompts whose chosen answer passed (0...1).
        public let passRate: Double
        /// Mean judge score (1...5).
        public let meanScore: Double
        /// USD per 100 prompts.
        public let costPer100: Double
        /// Share of prompts sent to Claude (Sonnet or Opus).
        public let claudeShare: Double
    }

    /// How the router's choice compared with the oracle's.
    public struct RouterBreakdown: Sendable, Equatable {
        /// Picked the cheapest route that passed.
        public var matched = 0
        /// Paid for a bigger route than needed.
        public var overRouted = 0
        /// Picked a route whose answer failed when a bigger one passed.
        public var underRouted = 0
        /// No route passed, so there was nothing to get right.
        public var unsolved = 0
    }

    /// A prompt the router got wrong, for tuning.
    public struct Misroute: Sendable, Identifiable {
        public let id: Int
        public let prompt: String
        public let router: QualityBenchmark.Column
        public let oracle: QualityBenchmark.Column
        public let isOverRouted: Bool
    }

    public let split: String?
    public let count: Int
    public let strategies: [StrategyResult]
    public let breakdown: RouterBreakdown
    public let misroutes: [Misroute]
    /// How much of the quality gap between always-on-device and always-Claude the router
    /// recovers (0 = on-device quality, 1 = Claude quality). Nil if there's no gap.
    public let gapRecovered: Double?
    /// Judgments the judge couldn't produce (counted as failing).
    public let judgeErrors: Int

    /// - Parameter split: "tuning", "heldout", or nil for every prompt.
    public init(_ run: QualityBenchmark.RunResult, split: String? = nil) {
        let cases = run.cases.filter { split == nil || $0.case.split == split }
        let rungs = QualityBenchmark.Column.rungs.filter(run.columns.contains)
        self.split = split
        count = cases.count
        judgeErrors = cases.flatMap(\.judgments).filter { $0.rationale.hasPrefix(QualityBenchmarkRunner.judgeErrorPrefix) }.count

        // The column each strategy would have used for each prompt.
        func oracle(_ result: QualityBenchmark.CaseResult) -> QualityBenchmark.Column? {
            rungs.first(where: result.passes) ?? rungs.last
        }
        func routerColumn(_ result: QualityBenchmark.CaseResult) -> QualityBenchmark.Column? {
            result.routerRoute.map(QualityBenchmark.Column.init(rung:)).flatMap { rungs.contains($0) ? $0 : nil }
        }

        func evaluate(_ strategy: Strategy, pick: (QualityBenchmark.CaseResult) -> QualityBenchmark.Column?) -> StrategyResult? {
            let picks = cases.compactMap { result in pick(result).map { (result, $0) } }
            guard !picks.isEmpty else { return nil }
            let n = Double(picks.count)
            return StrategyResult(
                strategy: strategy,
                passRate: Double(picks.filter { $0.0.passes($0.1) }.count) / n,
                meanScore: Double(picks.map { $0.0.score($0.1) }.reduce(0, +)) / n,
                costPer100: picks.map { $0.0.answer($0.1)?.cost ?? 0 }.reduce(0, +) / n * 100,
                claudeShare: Double(picks.filter { $0.1.route == .claude }.count) / n
            )
        }

        var results: [StrategyResult] = []
        let router = evaluate(.router, pick: routerColumn)
        if let router { results.append(router) }
        if rungs.contains(.onDevice), let value = evaluate(.alwaysOnDevice, pick: { _ in .onDevice }) { results.append(value) }
        if rungs.contains(.claude), let value = evaluate(.alwaysClaude, pick: { _ in .claude }) { results.append(value) }
        if run.columns.contains(.claudeDeep), let value = evaluate(.alwaysClaudeDeep, pick: { _ in .claudeDeep }) { results.append(value) }
        if let random = Self.randomSameMix(cases: cases, rungs: rungs, routerColumn: routerColumn) { results.append(random) }
        if let value = evaluate(.oracle, pick: oracle) { results.append(value) }
        strategies = results

        var breakdown = RouterBreakdown()
        var misroutes: [Misroute] = []
        for result in cases {
            guard let chosen = routerColumn(result), let best = oracle(result) else { continue }
            if !rungs.contains(where: result.passes) {
                breakdown.unsolved += 1
            } else if chosen == best {
                breakdown.matched += 1
            } else if chosen > best {
                breakdown.overRouted += 1
                misroutes.append(.init(id: result.id, prompt: result.case.prompt, router: chosen, oracle: best, isOverRouted: true))
            } else {
                // A cheaper route than the oracle's means its answer failed.
                breakdown.underRouted += 1
                misroutes.append(.init(id: result.id, prompt: result.case.prompt, router: chosen, oracle: best, isOverRouted: false))
            }
        }
        self.breakdown = breakdown
        self.misroutes = misroutes

        let onDevice = results.first { $0.strategy == .alwaysOnDevice }?.passRate
        let claude = results.first { $0.strategy == .alwaysClaude }?.passRate
        if let routerRate = router?.passRate, let onDevice, let claude, claude - onDevice > 0.0001 {
            gapRecovered = (routerRate - onDevice) / (claude - onDevice)
        } else {
            gapRecovered = nil
        }
    }

    /// The router's route shares applied to every prompt: the expected quality and cost of
    /// sending each prompt to a random route with the same overall mix.
    static func randomSameMix(
        cases: [QualityBenchmark.CaseResult],
        rungs: [QualityBenchmark.Column],
        routerColumn: (QualityBenchmark.CaseResult) -> QualityBenchmark.Column?
    ) -> StrategyResult? {
        let routed = cases.compactMap(routerColumn)
        guard !routed.isEmpty, !cases.isEmpty else { return nil }
        let n = Double(cases.count)
        var passRate = 0.0, meanScore = 0.0, costPer100 = 0.0, claudeShare = 0.0
        for rung in rungs {
            let share = Double(routed.filter { $0 == rung }.count) / Double(routed.count)
            guard share > 0 else { continue }
            passRate += share * Double(cases.filter { $0.passes(rung) }.count) / n
            meanScore += share * Double(cases.map { $0.score(rung) }.reduce(0, +)) / n
            costPer100 += share * cases.map { $0.answer(rung)?.cost ?? 0 }.reduce(0, +) / n * 100
            if rung.route == .claude { claudeShare += share }
        }
        return StrategyResult(strategy: .randomSameMix, passRate: passRate, meanScore: meanScore, costPer100: costPer100, claudeShare: claudeShare)
    }

    public func result(for strategy: Strategy) -> StrategyResult? {
        strategies.first { $0.strategy == strategy }
    }

    /// README-ready Markdown: the strategy table, the router's breakdown and its misroutes.
    public func markdown(title: String) -> String {
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        var lines = ["### \(title) (\(count) prompts)", ""]
        lines.append("| Strategy | Answers passed | Mean score | Cost per 100 prompts | Sent to Claude |")
        lines.append("|---|---|---|---|---|")
        for result in strategies {
            let name = result.strategy == .router ? "**\(result.strategy.displayName)**" : result.strategy.displayName
            lines.append("| \(name) | \(percent(result.passRate)) | \(String(format: "%.2f", result.meanScore)) | $\(String(format: "%.2f", result.costPer100)) | \(percent(result.claudeShare)) |")
        }
        lines.append("")
        let b = breakdown
        lines.append("Router vs the cheapest good-enough route: \(b.matched) matched, \(b.overRouted) over-routed (paid more than needed), \(b.underRouted) under-routed (answer failed where a bigger model passed), \(b.unsolved) no route passed.")
        if let gapRecovered {
            lines.append("It recovers \(percent(gapRecovered)) of the quality gap between always-on-device and always-Claude.")
        }
        if judgeErrors > 0 {
            lines.append("\(judgeErrors) answers couldn't be judged and count as failing.")
        }
        if !misroutes.isEmpty {
            lines.append("")
            lines.append("| # | Prompt | Router | Cheapest good-enough |")
            lines.append("|---|---|---|---|")
            for miss in misroutes {
                let prompt = miss.prompt.count > 80 ? String(miss.prompt.prefix(80)) + "…" : miss.prompt
                lines.append("| \(miss.id) | \(prompt.replacingOccurrences(of: "|", with: "\\|")) | \(miss.router.displayName) | \(miss.oracle.displayName) |")
            }
        }
        return lines.joined(separator: "\n")
    }
}
