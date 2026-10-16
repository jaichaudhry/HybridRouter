import Foundation

/// Runs the answer-quality benchmark: for each prompt, records the router's choice, answers on
/// every measurable column, and has the judge grade each answer.
///
/// - Columns follow the providers' real availability. A route served by a stand-in (e.g. Apple
///   Cloud simulated on-device) isn't measured, and the router sees it as unavailable, so its
///   choices match the app as shipped.
/// - Spend (answers plus judging) is tracked; the run stops before a prompt that would likely
///   take it past the cap.
/// - With a checkpoint file, progress is saved after every prompt and a later run resumes.
@MainActor
public final class QualityBenchmarkRunner {
    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let spent: Double
        /// The prompt being measured, or nil when the run has finished.
        public let current: String?

        public init(done: Int, total: Int, spent: Double, current: String?) {
            self.done = done
            self.total = total
            self.spent = spent
            self.current = current
        }
    }

    /// A fresh session whose `column.route` slot serves that column's model.
    public typealias SessionFactory = @MainActor (QualityBenchmark.Column) -> RoutedSession

    public private(set) var result: QualityBenchmark.RunResult
    public let spendCap: Double

    private let makeSession: SessionFactory
    private let judge: any AnswerJudge
    private let router: Router
    private let checkpoint: URL?

    /// - Parameters:
    ///   - makeSession: sessions for each column. `.claudeDeep` should put the deep (Opus)
    ///     provider in the Claude slot.
    ///   - spendCap: USD. The run stops before a prompt likely to cross it.
    ///   - checkpoint: where to save progress after each prompt. An existing checkpoint with the
    ///     same columns is resumed.
    ///   - device, classifierName, judgeModelID: recorded in the result.
    ///   - detectsExactAnswers: route with the exact-answer detector, as the app does.
    ///   - only: measure just these columns, e.g. to skip Opus on a test set. Others are listed
    ///     as not measured. Nil measures every available one.
    public init(
        makeSession: @escaping SessionFactory,
        judge: any AnswerJudge,
        classifier: any RouteClassifier,
        mapping: ComplexityMapping = .standard,
        spendCap: Double,
        checkpoint: URL? = nil,
        device: String,
        classifierName: String,
        judgeModelID: String,
        startedAt: Date = .now,
        detectsExactAnswers: Bool = false,
        only: Set<QualityBenchmark.Column>? = nil
    ) {
        self.makeSession = makeSession
        self.judge = judge
        self.router = Router(classifier: classifier, mapping: mapping, detectsExactAnswers: detectsExactAnswers)
        self.spendCap = spendCap
        self.checkpoint = checkpoint

        var columns: [QualityBenchmark.Column] = []
        var unmeasured: [String: String] = [:]
        for column in QualityBenchmark.Column.allCases {
            if let only, !only.contains(column) {
                unmeasured[column.rawValue] = "Not part of this run"
                continue
            }
            let session = makeSession(column)
            let provider = session.provider(for: column.route)
            if provider.isSimulated {
                unmeasured[column.rawValue] = "Simulated on the on-device model, so not measured"
            } else if case .unavailable(let reason) = session.availability(of: column.route) {
                unmeasured[column.rawValue] = reason
            } else {
                columns.append(column)
            }
        }
        let fresh = QualityBenchmark.RunResult(
            device: device, classifier: classifierName, judgeModelID: judgeModelID,
            startedAt: startedAt, columns: columns, unmeasured: unmeasured
        )
        if let checkpoint,
           let data = try? Data(contentsOf: checkpoint),
           let saved = try? QualityBenchmark.RunResult.load(data),
           saved.columns == columns {
            var resumed = saved
            resumed.stoppedAtSpendCap = false
            result = resumed
        } else {
            result = fresh
        }
    }

    /// Measures every case not already in the result. Stops early when cancelled or at the cap.
    @discardableResult
    public func run(
        _ cases: [QualityBenchmark.Case],
        onProgress: (Progress) -> Void = { _ in }
    ) async -> QualityBenchmark.RunResult {
        result.stoppedAtSpendCap = false
        let done = Set(result.cases.map(\.id))
        let pending = cases.filter { !done.contains($0.id) }
        let total = result.cases.count + pending.count
        for benchmarkCase in pending {
            if Task.isCancelled { break }
            // Stop before a prompt that would probably cross the cap, using the average so far.
            let average = result.cases.isEmpty ? 0 : result.spent / Double(result.cases.count)
            if result.spent + average > spendCap {
                result.stoppedAtSpendCap = true
                break
            }
            onProgress(Progress(done: result.cases.count, total: total, spent: result.spent, current: benchmarkCase.prompt))
            let measured = await measure(benchmarkCase)
            if Task.isCancelled { break }
            result.cases.append(measured)
            result.spent += measured.answers.map(\.cost).reduce(0, +)
                + measured.judgments.compactMap(\.cost).reduce(0, +)
            saveCheckpoint()
        }
        saveCheckpoint()
        onProgress(Progress(done: result.cases.count, total: total, spent: result.spent, current: nil))
        return result
    }

    /// Adds a column to a finished run without re-answering the others: every prompt in `run` is
    /// answered on `column` and graded, `concurrency` prompts at a time. Resumes from the
    /// checkpoint if it holds the same run. Stops early when cancelled, at the cap (counting only
    /// this column's spend), or when the provider reports its rate limit.
    ///
    /// A column served by a stand-in or unavailable provider isn't added: `run` comes back as
    /// is. Adding Apple Cloud also recomputes the router's choices as if Apple Cloud had been
    /// available, from the run's own classifications (see ``QualityBenchmark/CaseResult/routedWithAppleCloud()``).
    @discardableResult
    public func addColumn(
        _ column: QualityBenchmark.Column,
        to run: QualityBenchmark.RunResult,
        concurrency: Int = 4,
        onProgress: (Progress) -> Void = { _ in }
    ) async -> QualityBenchmark.RunResult {
        let probe = makeSession(column).provider(for: column.route)
        guard !probe.isSimulated, probe.availability.isAvailable else { return run }

        var extended = run
        if let checkpoint, let data = try? Data(contentsOf: checkpoint),
           let saved = try? QualityBenchmark.RunResult.load(data),
           // JSON dates keep whole seconds only.
           abs(saved.startedAt.timeIntervalSince(run.startedAt)) < 1,
           saved.cases.map(\.id) == run.cases.map(\.id), saved.columns.contains(column) {
            extended = saved
        }
        if !extended.columns.contains(column) {
            extended.columns.append(column)
            extended.columns.sort()
            extended.unmeasured[column.rawValue] = nil
        }
        if column == .appleCloud {
            extended.cases = extended.cases.map { $0.routedWithAppleCloud() }
            extended.routerNote = "Router choices recomputed for Apple Cloud from the original run's classifications."
        }
        extended.stoppedAtSpendCap = false
        extended.stoppedAtRateLimit = nil
        result = extended

        var added = 0.0
        var done = 0
        let pending = result.cases.indices.filter { result.cases[$0].answer(column) == nil }
        let total = pending.count
        for batchStart in stride(from: 0, to: pending.count, by: max(1, concurrency)) {
            if Task.isCancelled { break }
            let batch = pending[batchStart..<min(batchStart + max(1, concurrency), pending.count)]
            // Stop before a batch that would probably cross the cap, using the average so far.
            let average = done == 0 ? 0 : added / Double(done)
            if added + average * Double(batch.count) > spendCap {
                result.stoppedAtSpendCap = true
                break
            }
            onProgress(Progress(done: done, total: total, spent: added, current: result.cases[batch.first!].case.prompt))
            // Main-actor tasks rather than a task group, as in `measure`.
            let tasks = batch.map { index in
                let benchmarkCase = result.cases[index].case
                return Task {
                    let answer = await self.answer(benchmarkCase, on: column)
                    let judgment = answer.failure == nil ? await self.judged(answer, for: benchmarkCase) : nil
                    return (index, answer, judgment)
                }
            }
            var hitRateLimit = false
            for task in tasks {
                let (index, answer, judgment) = await task.value
                // Leave the prompt pending: the limit says nothing about the answer's quality.
                if answer.failure == FailureCause.rateLimited.label {
                    hitRateLimit = true
                    continue
                }
                let measured = result.cases[index]
                result.cases[index] = QualityBenchmark.CaseResult(
                    case: measured.case,
                    routerRoute: measured.routerRoute,
                    routerReason: measured.routerReason,
                    routerLatency: measured.routerLatency,
                    answers: measured.answers + [answer],
                    judgments: measured.judgments + (judgment.map { [$0] } ?? [])
                )
                let cost = answer.cost + (judgment?.cost ?? 0)
                added += cost
                result.spent += cost
                done += 1
            }
            saveCheckpoint()
            if hitRateLimit {
                result.stoppedAtRateLimit = true
                break
            }
            if Task.isCancelled { break }
        }
        saveCheckpoint()
        onProgress(Progress(done: done, total: total, spent: added, current: nil))
        return result
    }

    /// Clears saved progress so the next run starts over.
    public func discardCheckpoint() {
        if let checkpoint { try? FileManager.default.removeItem(at: checkpoint) }
    }

    // MARK: One prompt

    private func measure(_ benchmarkCase: QualityBenchmark.Case) async -> QualityBenchmark.CaseResult {
        // The router sees only measured rungs as available, matching the app as shipped.
        let input = RoutingInput(availability: result.routerAvailability, previousPrompt: benchmarkCase.previousPrompt)
        let routing = await router.route(benchmarkCase.prompt, input: input)
        var routerLatency: TimeInterval?
        if case .routed(_, let run) = routing { routerLatency = run?.latency }

        // Every column answers at once. (Main-actor tasks rather than a task group: a group here
        // trips a Swift 6.4 isolation checker bug, as in CompareModel.)
        let answerTasks = result.columns.map { column in
            Task { await self.answer(benchmarkCase, on: column) }
        }
        var answers: [QualityBenchmark.Answer] = []
        for task in answerTasks { answers.append(await task.value) }

        let judgeTasks = answers.filter { $0.failure == nil }.map { answer in
            Task { await self.judged(answer, for: benchmarkCase) }
        }
        var judgments: [QualityBenchmark.Judgment] = []
        for task in judgeTasks { judgments.append(await task.value) }

        return QualityBenchmark.CaseResult(
            case: benchmarkCase,
            routerRoute: routing.decision?.route,
            routerReason: routing.decision?.reason,
            routerLatency: routerLatency,
            answers: answers,
            judgments: judgments
        )
    }

    private func answer(_ benchmarkCase: QualityBenchmark.Case, on column: QualityBenchmark.Column) async -> QualityBenchmark.Answer {
        let session = makeSession(column)
        let modelID = session.provider(for: column.route).modelID
        do {
            let reply = try await session.respond(to: benchmarkCase.prompt, decision: .forced(column.route))
            if reply.content.isEmpty {
                return .init(column: column, modelID: modelID, text: "", metrics: reply.metrics, failure: "Empty reply")
            }
            return .init(column: column, modelID: modelID, text: reply.text, metrics: reply.metrics, failure: nil)
        } catch let failure as RoutedSession.StepFailure {
            return .init(column: column, modelID: modelID, text: "", metrics: failure.metrics, failure: FailureCause(failure).label)
        } catch {
            return .init(column: column, modelID: modelID, text: "", metrics: nil, failure: FailureCause(error).label)
        }
    }

    /// Grades an answer, retrying once. A judge that fails twice records a failing grade whose
    /// rationale starts with "Judge error", so reports can count and exclude them.
    private func judged(_ answer: QualityBenchmark.Answer, for benchmarkCase: QualityBenchmark.Case) async -> QualityBenchmark.Judgment {
        var lastError: (any Error)?
        for _ in 0..<2 {
            do {
                let verdict = try await judge.judge(answer.text, to: benchmarkCase)
                return .init(column: answer.column, passes: verdict.passes, score: verdict.score, rationale: verdict.rationale, cost: verdict.cost)
            } catch {
                lastError = error
            }
        }
        return .init(column: answer.column, passes: false, score: 1,
                     rationale: "\(Self.judgeErrorPrefix): \(lastError.map { String(describing: $0) } ?? "unknown")", cost: nil)
    }

    nonisolated static let judgeErrorPrefix = "Judge error"

    private func saveCheckpoint() {
        guard let checkpoint, let data = try? result.encoded() else { return }
        try? data.write(to: checkpoint, options: .atomic)
    }
}
