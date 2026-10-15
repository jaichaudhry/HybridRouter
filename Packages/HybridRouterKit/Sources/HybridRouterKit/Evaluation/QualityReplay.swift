import Foundation

/// Re-scores routing against a finished run's saved answers. Every prompt was already answered
/// on every route and graded, so only the router runs again: any routing change can be measured
/// for the cost of the on-device classifier, which is free.
public enum QualityReplay {
    /// The run with each prompt's router choice replaced by `router`'s.
    ///
    /// The router sees the run's measured routes as available, as in the benchmark itself.
    /// - Parameter split: replay only this split's prompts ("heldout", "tuning", "test"); others
    ///   are dropped from the result. Nil replays every prompt.
    @MainActor
    public static func reroute(
        _ run: QualityBenchmark.RunResult,
        with router: Router,
        split: String? = nil,
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> QualityBenchmark.RunResult {
        var replayed = run
        let cases = run.cases.filter { split == nil || $0.case.split == split }
        replayed.cases = []
        let availability = run.routerAvailability
        for (index, measured) in cases.enumerated() {
            if Task.isCancelled { break }
            onProgress(index, cases.count)
            let input = RoutingInput(availability: availability, previousPrompt: measured.case.previousPrompt)
            let routing = await router.route(measured.case.prompt, input: input)
            var latency: TimeInterval?
            if case .routed(_, let classifierRun) = routing { latency = classifierRun?.latency }
            replayed.cases.append(QualityBenchmark.CaseResult(
                case: measured.case,
                routerRoute: routing.decision?.route,
                routerReason: routing.decision?.reason,
                routerLatency: latency,
                answers: measured.answers,
                judgments: measured.judgments
            ))
        }
        onProgress(replayed.cases.count, cases.count)
        replayed.routerNote = "Router replayed on the saved answers."
        return replayed
    }

    /// How one routing of a run compares with another routing of the same prompts.
    public struct Comparison: Sendable, Equatable {
        public let count: Int
        /// Change in the share of good-enough answers, in points (e.g. 2.7 = +2.7 points).
        public let passDelta: Double
        public let passInterval: ClosedRange<Double>
        /// Relative change in cost (e.g. -0.13 = 13% cheaper).
        public let costChange: Double
        public let costInterval: ClosedRange<Double>
        /// How many prompts each version routed differently.
        public let changedRoutes: Int

        /// One line for a report, e.g. "+2.7 points (-0.7 to +6.0), 13% cheaper (4% to 23% cheaper)".
        public var summary: String {
            func points(_ value: Double) -> String { String(format: "%+.1f", value) }
            func change(_ value: Double) -> String {
                let percent = Int((abs(value) * 100).rounded())
                return value < 0 ? "\(percent)% cheaper" : (percent == 0 ? "same cost" : "\(percent)% dearer")
            }
            return "\(points(passDelta)) points (\(points(passInterval.lowerBound)) to \(points(passInterval.upperBound))), "
                + "\(change(costChange)) (\(change(costInterval.lowerBound)) to \(change(costInterval.upperBound))), "
                + "\(changedRoutes) of \(count) prompts routed differently"
        }
    }

    /// Paired bootstrap comparison of `candidate`'s routing with `baseline`'s over the prompts
    /// both contain, with 95% intervals. Seeded, so the same inputs give the same intervals.
    public static func compare(
        _ candidate: QualityBenchmark.RunResult,
        to baseline: QualityBenchmark.RunResult,
        split: String? = nil,
        resamples: Int = 4000,
        seed: UInt64 = 1
    ) -> Comparison? {
        let base = Dictionary(uniqueKeysWithValues: baseline.cases.map { ($0.id, $0) })
        let rungs = Set(QualityBenchmark.Column.rungs.filter(candidate.columns.contains))
        func outcome(_ result: QualityBenchmark.CaseResult) -> (pass: Double, cost: Double)? {
            guard let route = result.routerRoute else { return nil }
            let column = QualityBenchmark.Column(rung: route)
            guard rungs.contains(column) else { return nil }
            return (result.passes(column) ? 1 : 0, result.answer(column)?.cost ?? 0)
        }
        var pairs: [(new: (pass: Double, cost: Double), old: (pass: Double, cost: Double))] = []
        var changed = 0
        for result in candidate.cases where split == nil || result.case.split == split {
            guard let old = base[result.id], let a = outcome(result), let b = outcome(old) else { continue }
            pairs.append((a, b))
            if result.routerRoute != old.routerRoute { changed += 1 }
        }
        guard !pairs.isEmpty else { return nil }

        func stats(_ sample: [Int]) -> (pass: Double, cost: Double) {
            var newPass = 0.0, oldPass = 0.0, newCost = 0.0, oldCost = 0.0
            for index in sample {
                newPass += pairs[index].new.pass; oldPass += pairs[index].old.pass
                newCost += pairs[index].new.cost; oldCost += pairs[index].old.cost
            }
            let n = Double(sample.count)
            return ((newPass - oldPass) / n * 100, oldCost > 0 ? newCost / oldCost - 1 : 0)
        }
        let all = stats(Array(pairs.indices))
        var generator = SplitMix64(seed: seed)
        var passes: [Double] = [], costs: [Double] = []
        for _ in 0..<resamples {
            let sample = (0..<pairs.count).map { _ in Int.random(in: 0..<pairs.count, using: &generator) }
            let s = stats(sample)
            passes.append(s.pass)
            costs.append(s.cost)
        }
        return Comparison(
            count: pairs.count,
            passDelta: all.pass,
            passInterval: percentile(passes, 0.025)...percentile(passes, 0.975),
            costChange: all.cost,
            costInterval: percentile(costs, 0.025)...percentile(costs, 0.975),
            changedRoutes: changed
        )
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }
}

extension QualityBenchmark.RunResult {
    /// What the router may choose from: the measured routing rungs, as in the app as shipped.
    public var routerAvailability: [Route: ProviderAvailability] {
        var availability: [Route: ProviderAvailability] = [:]
        for route in Route.allCases {
            let column = QualityBenchmark.Column(rung: route)
            availability[route] = columns.contains(column)
                ? .available
                : .unavailable(reason: unmeasured[column.rawValue] ?? "Not measured")
        }
        return availability
    }
}

/// A small seeded generator, so bootstrap intervals are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
