import Foundation

/// Summarizes a multi-turn run: each strategy's quality and cost, then what each group measures.
public struct MultiTurnReport: Sendable {
    public struct StrategySummary: Sendable {
        public let strategy: MultiTurnBenchmark.Strategy
        public let turns: Int
        public let passRate: Double
        public let meanScore: Double
        /// Share of conversations where every turn passed.
        public let conversationPassRate: Double
        public let costPerConversation: Double
        /// Share of answered turns answered on the phone.
        public let onDeviceShare: Double
        public let unanswered: Int
    }

    public struct FollowUps: Sendable {
        /// Router turns tagged as follow-ups, after a turn that was answered.
        public let count: Int
        /// Answered on the same route as the turn before.
        public let stayed: Int
        public let stayedPassRate: Double?
        public let movedPassRate: Double?
        /// Follow-ups tagged "harder" that moved to a larger route.
        public let harder: Int
        public let harderMovedUp: Int
    }

    public struct Privacy: Sendable {
        /// Turns tagged private, and how many the guard flagged.
        public let privateTurns: Int
        public let flagged: Int
        /// Untagged turns the guard flagged anyway.
        public let unexpectedlyFlagged: Int
        /// Secrets found in requests to the cloud model, across router runs. Must be 0.
        public let leaks: Int
        /// Turns that build on a private turn: pass rate on the router and with always-Claude.
        public let afterPrivateTurns: Int
        public let afterPrivateRouterPassRate: Double?
        public let afterPrivateClaudePassRate: Double?
        /// Of those turns, how many the router answered with the cloud model, which saw the
        /// private turns only as placeholders.
        public let afterPrivateOnCloud: Int
    }

    public struct LongChats: Sendable {
        /// Router turns that moved up because the chat was too long for a smaller model.
        public let movedUp: Int
        /// Turns answered from only the most recent turns, per strategy.
        public let trimmed: [MultiTurnBenchmark.Strategy: Int]
        /// Pass rate on questions about early details, per strategy.
        public let recallPassRate: [MultiTurnBenchmark.Strategy: Double]
    }

    public struct Failures: Sendable {
        /// Turns where at least one injected fault fired.
        public let faultedTurns: Int
        public let answered: Int
        public let passed: Int
        /// Faulted turns finally answered on-device after the cloud model kept failing.
        public let fellBack: Int
        /// Faults that never fired because the router didn't send that turn to the cloud model.
        public let notFired: Int
    }

    public let split: String?
    public let conversations: Int
    public let strategies: [StrategySummary]
    public let followUps: FollowUps
    public let privacy: Privacy
    public let longChats: LongChats
    public let failures: Failures
    /// Grades that failed because the judge errored, counted as failing.
    public let judgeErrors: Int

    /// - Parameter split: "tuning", "heldout", or nil for every conversation.
    public init(_ run: MultiTurnBenchmark.RunResult, dataset: MultiTurnBenchmark.Dataset, split: String? = nil) {
        self.split = split
        let conversations = dataset.conversations.filter { split == nil || $0.split == split }
        let byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let runs = run.runs.filter { byID[$0.conversationID] != nil }
        self.conversations = Set(runs.map(\.conversationID)).count
        judgeErrors = runs.flatMap(\.turns).filter { $0.grade?.isJudgeError ?? false }.count

        // Strategies are compared on the conversations every strategy ran, so the numbers line up.
        let compared = conversations.filter { $0.group != .failure }.map(\.id).filter { id in
            MultiTurnBenchmark.Strategy.allCases.allSatisfy { run.run(id, $0) != nil }
        }
        strategies = MultiTurnBenchmark.Strategy.allCases.compactMap { strategy in
            let strategyRuns = compared.compactMap { run.run($0, strategy) }
            guard !strategyRuns.isEmpty else { return nil }
            let turns = strategyRuns.flatMap(\.turns)
            let answered = turns.filter(\.isAnswered)
            return StrategySummary(
                strategy: strategy,
                turns: turns.count,
                passRate: Self.rate(turns.filter(\.passes).count, of: turns.count) ?? 0,
                meanScore: turns.isEmpty ? 0 : Double(turns.map { $0.grade?.score ?? 1 }.reduce(0, +)) / Double(turns.count),
                conversationPassRate: Self.rate(strategyRuns.filter(\.allPassed).count, of: strategyRuns.count) ?? 0,
                costPerConversation: strategyRuns.map(\.cost).reduce(0, +) / Double(strategyRuns.count),
                onDeviceShare: Self.rate(answered.filter { $0.route == .onDevice }.count, of: answered.count) ?? 0,
                unanswered: turns.count - answered.count
            )
        }

        let routerRuns = runs.filter { $0.strategy == .router }
        func tagged(_ tag: MultiTurnBenchmark.Tag, in run: MultiTurnBenchmark.ConversationRun) -> [MultiTurnBenchmark.TurnResult] {
            guard let conversation = byID[run.conversationID] else { return [] }
            return run.turns.filter { conversation.turns[$0.index].has(tag) }
        }

        // Follow-ups: did the router stay on the route that answered the turn before?
        var stayed: [MultiTurnBenchmark.TurnResult] = []
        var moved: [MultiTurnBenchmark.TurnResult] = []
        var harder = 0
        var harderMovedUp = 0
        for routerRun in routerRuns {
            guard let conversation = byID[routerRun.conversationID], conversation.group != .failure else { continue }
            for turn in routerRun.turns where turn.index > 0 && conversation.turns[turn.index].has(.followUp) {
                let previous = routerRun.turns[turn.index - 1]
                guard previous.isAnswered, let route = turn.route, let previousRoute = previous.route else { continue }
                if route == previousRoute { stayed.append(turn) } else { moved.append(turn) }
                if conversation.turns[turn.index].has(.harder) {
                    harder += 1
                    if Self.order(route) > Self.order(previousRoute) { harderMovedUp += 1 }
                }
            }
        }
        followUps = FollowUps(
            count: stayed.count + moved.count,
            stayed: stayed.count,
            stayedPassRate: Self.rate(stayed.filter(\.passes).count, of: stayed.count),
            movedPassRate: Self.rate(moved.filter(\.passes).count, of: moved.count),
            harder: harder,
            harderMovedUp: harderMovedUp
        )

        // Privacy: the guard's flags, leaks, and what keeping turns private costs in quality.
        let privateTurns = routerRuns.flatMap { tagged(.private, in: $0) }
        let unexpected = routerRuns.flatMap { routerRun in
            routerRun.turns.filter { turn in
                turn.privacyReason != nil && !(byID[routerRun.conversationID]?.turns[turn.index].has(.private) ?? true)
            }
        }
        let afterPrivate = routerRuns.flatMap { tagged(.afterPrivate, in: $0) }
        let afterPrivateClaude = runs.filter { $0.strategy == .claude }.flatMap { tagged(.afterPrivate, in: $0) }
        privacy = Privacy(
            privateTurns: privateTurns.count,
            flagged: privateTurns.filter { $0.privacyReason != nil }.count,
            unexpectedlyFlagged: unexpected.count,
            leaks: routerRuns.map(\.leaks.count).reduce(0, +),
            afterPrivateTurns: afterPrivate.count,
            afterPrivateRouterPassRate: Self.rate(afterPrivate.filter(\.passes).count, of: afterPrivate.count),
            afterPrivateClaudePassRate: Self.rate(afterPrivateClaude.filter(\.passes).count, of: afterPrivateClaude.count),
            afterPrivateOnCloud: afterPrivate.filter { $0.route == .cloud }.count
        )

        // Long chats: moving up versus answering from the most recent turns, and recall.
        let longRuns = runs.filter { byID[$0.conversationID]?.group == .longChat }
        var trimmed: [MultiTurnBenchmark.Strategy: Int] = [:]
        var recall: [MultiTurnBenchmark.Strategy: Double] = [:]
        for strategy in MultiTurnBenchmark.Strategy.allCases {
            let strategyRuns = longRuns.filter { $0.strategy == strategy }
            guard !strategyRuns.isEmpty else { continue }
            trimmed[strategy] = strategyRuns.flatMap(\.turns).filter(\.leftOutEarlierTurns).count
            let recallTurns = strategyRuns.flatMap { tagged(.recall, in: $0) }
            recall[strategy] = Self.rate(recallTurns.filter(\.passes).count, of: recallTurns.count)
        }
        longChats = LongChats(
            movedUp: longRuns.filter { $0.strategy == .router }.flatMap(\.turns).filter(\.movedUp).count,
            trimmed: trimmed,
            recallPassRate: recall
        )

        // Failures: did faulted turns still get answered, and at what cost in time?
        let failureRuns = routerRuns.filter { byID[$0.conversationID]?.group == .failure }
        let faulted = failureRuns.flatMap(\.turns).filter { $0.faultsFired > 0 }
        let armed = failureRuns.flatMap { failureRun in
            (byID[failureRun.conversationID]?.faults ?? []).compactMap { fault in
                failureRun.turns.first { $0.index == fault.turn - 1 }
            }
        }
        failures = Failures(
            faultedTurns: faulted.count,
            answered: faulted.filter(\.isAnswered).count,
            passed: faulted.filter(\.passes).count,
            fellBack: faulted.filter { $0.isAnswered && $0.route == .onDevice }.count,
            notFired: armed.filter { $0.faultsFired == 0 }.count
        )
    }

    private static func rate(_ count: Int, of total: Int) -> Double? {
        total == 0 ? nil : Double(count) / Double(total)
    }

    private static func order(_ route: Route) -> Int {
        Route.allCases.firstIndex(of: route)!
    }

    // MARK: Markdown

    public func markdown(title: String) -> String {
        var lines = ["## \(title) (\(conversations) conversations)", ""]
        if !strategies.isEmpty {
            lines += [
                "| Strategy | Turns passed | Whole conversations passed | Mean score | Cost per conversation | On the phone |",
                "|---|---|---|---|---|---|",
            ]
            for summary in strategies {
                lines.append("| \(summary.strategy.displayName) | \(Self.percent(summary.passRate)) | \(Self.percent(summary.conversationPassRate)) | \(String(format: "%.2f", summary.meanScore)) | \(Self.dollars(summary.costPerConversation)) | \(Self.percent(summary.onDeviceShare)) |")
            }
            lines.append("")
        }
        lines.append("- **Follow-ups:** \(followUps.stayed) of \(followUps.count) stayed on the model that answered before"
            + " (passed \(Self.percent(followUps.stayedPassRate)) when they stayed, \(Self.percent(followUps.movedPassRate)) when they moved);"
            + " \(followUps.harderMovedUp) of \(followUps.harder) harder follow-ups moved to a larger model.")
        lines.append("- **Privacy:** \(privacy.leaks == 0 ? "no leaks" : "**\(privacy.leaks) leaks**");"
            + " the guard flagged \(privacy.flagged) of \(privacy.privateTurns) private turns, plus \(privacy.unexpectedlyFlagged) others."
            + " Turns building on a private turn passed \(Self.percent(privacy.afterPrivateRouterPassRate)) on the router"
            + " vs \(Self.percent(privacy.afterPrivateClaudePassRate)) always on Claude;"
            + " the router sent \(privacy.afterPrivateOnCloud) of \(privacy.afterPrivateTurns) of them to Claude, which saw the private turns as placeholders.")
        let trimmedText = MultiTurnBenchmark.Strategy.allCases.compactMap { strategy in
            longChats.trimmed[strategy].map { "\(strategy.displayName.lowercased()) \($0)" }
        }.joined(separator: ", ")
        let recallText = MultiTurnBenchmark.Strategy.allCases.compactMap { strategy in
            longChats.recallPassRate[strategy].map { "\(strategy.displayName.lowercased()) \(Self.percent($0))" }
        }.joined(separator: ", ")
        lines.append("- **Long chats:** the router moved up \(longChats.movedUp) times;"
            + " turns answered from recent turns only: \(trimmedText.isEmpty ? "none" : trimmedText)."
            + " Recall questions passed: \(recallText.isEmpty ? "n/a" : recallText).")
        lines.append("- **Failures:** \(failures.answered) of \(failures.faultedTurns) turns with injected failures were still answered"
            + " (\(failures.passed) passed, \(failures.fellBack) by falling back to on-device);"
            + " \(failures.notFired) faults didn't fire because the turn didn't go to Claude.")
        if judgeErrors > 0 {
            lines.append("- \(judgeErrors) grades failed because the judge errored; they count as failing.")
        }
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
    }

    private static func dollars(_ value: Double) -> String {
        String(format: "$%.3f", value)
    }
}
