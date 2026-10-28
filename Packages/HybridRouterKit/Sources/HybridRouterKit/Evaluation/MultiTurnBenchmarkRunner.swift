import Foundation

/// Runs the multi-turn benchmark: each conversation under each strategy, start to finish, through
/// a ``TurnCoordinator`` as the app runs turns, then has the judge grade every turn.
///
/// - The router strategy checks each message with the ``PrivacyGuard``, as the app does. The
///   forced strategies don't: always-Claude is the quality ceiling, private turns included.
/// - Each conversation gets a ``CloudTap`` in front of the cloud model: it records what the cloud
///   model received, for the leak check, and injects a conversation's faults (router only).
/// - Spend (answers plus judging) is tracked; the run stops before a conversation that would
///   likely take it past the cap. With a checkpoint, progress is saved after every conversation
///   and strategy, and a later run resumes.
@MainActor
public final class MultiTurnBenchmarkRunner {
    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let spent: Double
        /// What's running, e.g. "Lisbon trip · Router · turn 3 of 5", or nil when finished.
        public let current: String?
    }

    /// A fresh session for a strategy. Its cloud provider must be wrapped with `tap.wrap(_:)`,
    /// and Apple Cloud must not be a stand-in, so the router sees the app's real choices.
    public typealias SessionFactory = @MainActor (MultiTurnBenchmark.Strategy, CloudTap) -> RoutedSession

    public private(set) var result: MultiTurnBenchmark.RunResult
    public let spendCap: Double

    private let dataset: MultiTurnBenchmark.Dataset
    private let makeSession: SessionFactory
    private let makeCoordinator: @MainActor () -> TurnCoordinator
    private let judge: any AnswerJudge
    private let privacyGuard: PrivacyGuard
    private let checkpoint: URL?
    private let judgeConcurrency: Int

    /// Longest earlier reply shown to the judge, in characters.
    static let judgeReplyLimit = 4_000

    public init(
        dataset: MultiTurnBenchmark.Dataset,
        makeSession: @escaping SessionFactory,
        makeCoordinator: @escaping @MainActor () -> TurnCoordinator,
        judge: any AnswerJudge,
        privacyGuard: PrivacyGuard = PrivacyGuard(),
        spendCap: Double,
        checkpoint: URL? = nil,
        device: String,
        classifierName: String,
        judgeModelID: String,
        startedAt: Date = .now,
        judgeConcurrency: Int = 4
    ) {
        self.dataset = dataset
        self.makeSession = makeSession
        self.makeCoordinator = makeCoordinator
        self.judge = judge
        self.privacyGuard = privacyGuard
        self.spendCap = spendCap
        self.checkpoint = checkpoint
        self.judgeConcurrency = max(1, judgeConcurrency)

        let probe = makeSession(.router, CloudTap())
        let available = Route.allCases.filter { probe.availability(of: $0).isAvailable && !probe.provider(for: $0).isSimulated }
        let fresh = MultiTurnBenchmark.RunResult(
            device: device, classifier: classifierName, judgeModelID: judgeModelID,
            cloudModelID: probe.provider(for: .cloud).modelID, startedAt: startedAt, availableRoutes: available
        )
        if let checkpoint, let data = try? Data(contentsOf: checkpoint),
           let saved = try? MultiTurnBenchmark.RunResult.load(data), saved.availableRoutes == available {
            var resumed = saved
            resumed.stoppedAtSpendCap = false
            result = resumed
        } else {
            result = fresh
        }
    }

    /// Runs every conversation and strategy not already in the result. Stops early when cancelled
    /// or at the cap.
    /// - Parameter only: conversation IDs to run, or nil for all.
    @discardableResult
    public func run(
        only: Set<String>? = nil,
        onProgress: (Progress) -> Void = { _ in }
    ) async -> MultiTurnBenchmark.RunResult {
        result.stoppedAtSpendCap = false
        if result.onDeviceContextSize == nil {
            result.onDeviceContextSize = await makeSession(.router, CloudTap()).provider(for: .onDevice).contextSize()
        }
        let units = dataset.conversations
            .filter { only?.contains($0.id) ?? true }
            .flatMap { conversation in conversation.strategies.map { (conversation, $0) } }
        let pending = units.filter { result.run($0.0.id, $0.1) == nil }
        let total = units.count
        for (offset, (conversation, strategy)) in pending.enumerated() {
            if Task.isCancelled { break }
            // Stop before a conversation that would probably cross the cap, using the average so far.
            let average = result.runs.isEmpty ? 0 : result.spent / Double(result.runs.count)
            if result.spent + average > spendCap {
                result.stoppedAtSpendCap = true
                break
            }
            let done = total - pending.count + offset
            let measured = await measure(conversation, strategy) { turn in
                onProgress(Progress(done: done, total: total, spent: self.result.spent,
                                    current: "\(conversation.title) · \(strategy.displayName) · turn \(turn) of \(conversation.turns.count)"))
            }
            if Task.isCancelled { break }
            result.runs.append(measured)
            result.spent += measured.cost + measured.judgeCost
            saveCheckpoint()
        }
        saveCheckpoint()
        onProgress(Progress(done: units.filter { result.run($0.0.id, $0.1) != nil }.count, total: total, spent: result.spent, current: nil))
        return result
    }

    /// Clears saved progress so the next run starts over.
    public func discardCheckpoint() {
        if let checkpoint { try? FileManager.default.removeItem(at: checkpoint) }
    }

    // MARK: One conversation

    private func measure(
        _ conversation: MultiTurnBenchmark.Conversation,
        _ strategy: MultiTurnBenchmark.Strategy,
        onTurn: (Int) -> Void
    ) async -> MultiTurnBenchmark.ConversationRun {
        let tap = CloudTap()
        let session = makeSession(strategy, tap)
        let coordinator = makeCoordinator()
        var answered: [(message: String, outcome: TurnCoordinator.Outcome, privacyReason: String?, fired: Int)] = []

        for (index, turn) in conversation.turns.enumerated() {
            if Task.isCancelled { break }
            onTurn(index + 1)
            let message = dataset.message(for: turn)
            let privacyReason = strategy == .router
                ? privacyGuard.assess(message, markedPrivate: turn.markedPrivate ?? false)?.label
                : nil
            tap.arm(strategy == .router ? conversation.faults(onTurn: index) : [])
            let outcome = await coordinator.run(
                .init(prompt: message, override: strategy.forcedRoute, privacyReason: privacyReason),
                in: session
            )
            answered.append((message, outcome, privacyReason, tap.disarm()))
        }

        let grades = await grade(answered.map { ($0.message, $0.outcome.content?.text ?? "") }, in: conversation)
        let turns = answered.enumerated().map { index, item in
            MultiTurnBenchmark.TurnResult(
                index: index,
                route: item.outcome.decision?.route,
                reason: item.outcome.decision?.reason,
                text: item.outcome.content?.text ?? "",
                failure: item.outcome.failure,
                steps: item.outcome.steps,
                privacyReason: item.privacyReason,
                movedUp: item.outcome.decision?.tooLongFor != nil,
                faultsFired: item.fired,
                grade: grades[index]
            )
        }
        return MultiTurnBenchmark.ConversationRun(
            conversationID: conversation.id,
            strategy: strategy,
            turns: turns,
            leaks: tap.leaked(conversation.secrets ?? []),
            cloudRequests: tap.requests.count
        )
    }

    // MARK: Grading

    /// Grades every answered turn, a few at a time. Unanswered turns get no grade and fail.
    private func grade(_ exchanges: [(message: String, reply: String)], in conversation: MultiTurnBenchmark.Conversation) async -> [MultiTurnBenchmark.Grade?] {
        var grades = [MultiTurnBenchmark.Grade?](repeating: nil, count: exchanges.count)
        let toGrade = exchanges.indices.filter { !exchanges[$0].reply.isEmpty }
        for batchStart in stride(from: 0, to: toGrade.count, by: judgeConcurrency) {
            let batch = toGrade[batchStart..<min(batchStart + judgeConcurrency, toGrade.count)]
            // Main-actor tasks rather than a task group, as in QualityBenchmarkRunner.
            let tasks = batch.map { index in
                let judgedCase = Self.judgedCase(index: index, exchanges: exchanges, conversation: conversation)
                let reply = exchanges[index].reply
                return Task { (index, await self.judged(reply, for: judgedCase)) }
            }
            for task in tasks {
                let (index, grade) = await task.value
                grades[index] = grade
            }
        }
        return grades
    }

    /// The judge's view of one turn: the earlier exchanges, this message and its answer key.
    static func judgedCase(
        index: Int,
        exchanges: [(message: String, reply: String)],
        conversation: MultiTurnBenchmark.Conversation
    ) -> QualityBenchmark.Case {
        let earlier = exchanges.prefix(index).map { exchange in
            let reply = exchange.reply.isEmpty ? "[No reply]" : String(exchange.reply.prefix(judgeReplyLimit))
            return "User:\n\(exchange.message)\n\nAssistant:\n\(reply)"
        }
        return QualityBenchmark.Case(
            id: index,
            split: conversation.split,
            group: conversation.group.rawValue,
            task: "conversation",
            difficulty: "",
            prompt: exchanges[index].message,
            criteria: conversation.turns[index].criteria,
            conversation: earlier.isEmpty ? nil : earlier.joined(separator: "\n\n---\n\n")
        )
    }

    /// Grades a reply, retrying once. A judge that fails twice records a failing grade whose
    /// rationale starts with "Judge error", so reports can count and exclude it.
    private func judged(_ reply: String, for judgedCase: QualityBenchmark.Case) async -> MultiTurnBenchmark.Grade {
        var lastError: (any Error)?
        for _ in 0..<2 {
            do {
                let verdict = try await judge.judge(reply, to: judgedCase)
                return .init(passes: verdict.passes, score: verdict.score, rationale: verdict.rationale, cost: verdict.cost)
            } catch {
                lastError = error
            }
        }
        return .init(passes: false, score: 1,
                     rationale: "\(QualityBenchmarkRunner.judgeErrorPrefix): \(lastError.map { String(describing: $0) } ?? "unknown")",
                     cost: nil)
    }

    private func saveCheckpoint() {
        guard let checkpoint, let data = try? result.encoded() else { return }
        try? data.write(to: checkpoint, options: .atomic)
    }
}
