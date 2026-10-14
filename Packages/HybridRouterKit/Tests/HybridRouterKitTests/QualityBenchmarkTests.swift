import Foundation
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

/// The report's arithmetic, on four hand-built prompts covering each outcome.
struct QualityReportTests {
    private static func benchmarkCase(_ id: Int, split: String = "heldout") -> QualityBenchmark.Case {
        .init(id: id, split: split, group: "chat", task: "chat", difficulty: "easy", prompt: "Prompt \(id)")
    }

    private static func answer(_ column: QualityBenchmark.Column, cost: Double) -> QualityBenchmark.Answer {
        let metrics = StepMetrics(
            decision: .forced(column.route), modelID: "m", timeToFirstToken: nil, totalLatency: 1,
            usage: TokenUsage(input: 1, cachedInput: 0, output: 1, reasoning: nil), estimatedCost: cost
        )
        return .init(column: column, modelID: "m", text: "answer", metrics: metrics, failure: nil)
    }

    /// A prompt where on-device and Claude pass as given, and the router chose `router`.
    private static func result(_ id: Int, onDevice: Bool, claude: Bool, router: Route) -> QualityBenchmark.CaseResult {
        .init(
            case: benchmarkCase(id),
            routerRoute: router, routerReason: nil, routerLatency: 0.5,
            answers: [answer(.onDevice, cost: 0), answer(.claude, cost: 0.01)],
            judgments: [
                .init(column: .onDevice, passes: onDevice, score: onDevice ? 5 : 1, rationale: "", cost: 0.001),
                .init(column: .claude, passes: claude, score: claude ? 5 : 1, rationale: "", cost: 0.001),
            ]
        )
    }

    private static let run: QualityBenchmark.RunResult = {
        var run = QualityBenchmark.RunResult(
            device: "test", classifier: "fake", judgeModelID: "judge", startedAt: Date(timeIntervalSince1970: 0),
            columns: [.onDevice, .claude], unmeasured: ["appleCloud": "No entitlement"]
        )
        run.cases = [
            result(1, onDevice: true, claude: true, router: .onDevice),   // matched
            result(2, onDevice: false, claude: true, router: .onDevice),  // under-routed
            result(3, onDevice: true, claude: true, router: .claude),     // over-routed
            result(4, onDevice: false, claude: false, router: .claude),   // unsolved
        ]
        return run
    }()

    @Test func strategiesScoreQualityAndCost() throws {
        let report = QualityReport(Self.run)
        let router = try #require(report.result(for: .router))
        #expect(router.passRate == 0.5)
        #expect(abs(router.costPer100 - 0.5) < 1e-9)
        #expect(router.claudeShare == 0.5)

        #expect(report.result(for: .alwaysOnDevice)?.passRate == 0.5)
        #expect(report.result(for: .alwaysOnDevice)?.costPer100 == 0)
        #expect(report.result(for: .alwaysClaude)?.passRate == 0.75)
        #expect(abs((report.result(for: .alwaysClaude)?.costPer100 ?? 0) - 1.0) < 1e-9)

        // Oracle: on-device for 1 and 3, Claude for 2, and Claude (the top rung) when nothing passes.
        let oracle = try #require(report.result(for: .oracle))
        #expect(oracle.passRate == 0.75)
        #expect(abs(oracle.costPer100 - 0.5) < 1e-9)
    }

    @Test func randomSameMixIsTheExactExpectation() throws {
        // The router sends half to each rung: 0.5 × 50% + 0.5 × 75% passing, 0.5 × $1.00 per 100.
        let random = try #require(QualityReport(Self.run).result(for: .randomSameMix))
        #expect(abs(random.passRate - 0.625) < 1e-9)
        #expect(abs(random.costPer100 - 0.5) < 1e-9)
        #expect(random.claudeShare == 0.5)
    }

    @Test func routerChoicesAreComparedWithTheOracle() {
        let report = QualityReport(Self.run)
        #expect(report.breakdown == .init(matched: 1, overRouted: 1, underRouted: 1, unsolved: 1))
        #expect(report.misroutes.map(\.id) == [2, 3])
        #expect(report.misroutes.first { $0.id == 3 }?.isOverRouted == true)
        // Same quality as always-on-device here, so none of the gap to Claude is recovered.
        #expect(report.gapRecovered == 0)
    }

    @Test func splitsAreReportedSeparately() {
        var run = Self.run
        run.cases.append(Self.result(5, onDevice: true, claude: true, router: .onDevice))
        run.cases[4] = .init(case: Self.benchmarkCase(5, split: "tuning"), routerRoute: .onDevice, routerReason: nil, routerLatency: nil,
                             answers: run.cases[4].answers, judgments: run.cases[4].judgments)
        #expect(QualityReport(run, split: "heldout").count == 4)
        #expect(QualityReport(run, split: "tuning").count == 1)
        #expect(QualityReport(run).count == 5)
    }

    @Test func markdownHasTheTableAndMisroutes() {
        let markdown = QualityReport(Self.run).markdown(title: "Held-out")
        #expect(markdown.contains("| **HybridRouter** | 50% |"))
        #expect(markdown.contains("1 matched, 1 over-routed"))
        #expect(markdown.contains("| 2 | Prompt 2 | On-device | Claude Sonnet |"))
    }

    @Test func runResultsRoundTripThroughJSON() throws {
        let decoded = try QualityBenchmark.RunResult.load(try Self.run.encoded())
        #expect(decoded.cases.map(\.id) == [1, 2, 3, 4])
        #expect(decoded.unmeasured == ["appleCloud": "No entitlement"])
        #expect(decoded.cases[1].passes(.claude))
    }

    @Test func benchmarkCasesDecode() throws {
        let json = #"[{"id": 101, "split": "heldout", "group": "chat", "task": "chat", "difficulty": "easy", "prompt": "Capital of Australia?", "criteria": "Canberra."}]"#
        let cases = try QualityBenchmark.load(Data(json.utf8))
        #expect(cases.first?.criteria == "Canberra.")
        #expect(cases.first?.previousPrompt == nil)
    }
}

/// The runner end to end, with fake models and a fake judge.
@MainActor
struct QualityBenchmarkRunnerTests {
    /// $15 per million tokens in and out, so a fake Claude reply (10 in, 5 out) costs $0.000225.
    private let costTable = CostTable(updated: "test", source: "test", models: [
        "apple-on-device": .init(input: 0, cachedInput: 0, output: 0),
        "claude-sonnet-5-5": .init(input: 15, cachedInput: 15, output: 15),
    ])

    private func cases(_ count: Int) -> [QualityBenchmark.Case] {
        (1...count).map { .init(id: $0, split: "heldout", group: "chat", task: "chat", difficulty: "easy", prompt: "Question \($0)") }
    }

    private func runner(
        judge: any AnswerJudge = FakeAnswerJudge.passing(containing: "claude"),
        classifier: FakeClassifier = .always("simple"),
        claudeAvailability: ProviderAvailability = .available,
        spendCap: Double = 100,
        checkpoint: URL? = nil
    ) -> QualityBenchmarkRunner {
        let costTable = costTable
        return QualityBenchmarkRunner(
            makeSession: { column in
                var appleCloud = FakeProvider(route: .appleCloud, reply: "cloud answer")
                appleCloud.isSimulated = true
                var claude = FakeProvider(route: .claude, reply: column == .claudeDeep ? "claude deep answer" : "claude answer")
                claude.availability = claudeAvailability
                return RoutedSession(
                    instructions: "Be brief.",
                    onDevice: FakeProvider(route: .onDevice, reply: "device answer"),
                    appleCloud: appleCloud,
                    claude: claude,
                    costTable: costTable
                )
            },
            judge: judge,
            classifier: classifier,
            spendCap: spendCap,
            checkpoint: checkpoint,
            device: "test", classifierName: "fake", judgeModelID: "judge"
        )
    }

    @Test func answersEveryMeasuredColumnAndJudgesEachAnswer() async throws {
        let result = await runner().run(cases(1))
        #expect(result.columns == [.onDevice, .claude, .claudeDeep])
        let first = try #require(result.cases.first)
        #expect(first.answers.map(\.column) == [.onDevice, .claude, .claudeDeep])
        #expect(first.answer(.claudeDeep)?.text == "claude deep answer")
        #expect(first.passes(.claude))
        #expect(!first.passes(.onDevice))
        #expect(first.routerRoute == .onDevice)
        #expect(result.spent > 0)
    }

    @Test func simulatedAppleCloudIsNotMeasured() async {
        let result = await runner().run(cases(1))
        #expect(!result.columns.contains(.appleCloud))
        #expect(result.unmeasured["appleCloud"]?.contains("Simulated") == true)
    }

    @Test func theRouterTreatsUnmeasuredRoutesAsUnavailable() async {
        // "moderate" maps to Apple Cloud, which isn't measured, so the router moves up to Claude,
        // as the shipped app does without the entitlement.
        let result = await runner(classifier: .always("moderate")).run(cases(1))
        #expect(result.cases.first?.routerRoute == .claude)
    }

    @Test func unavailableClaudeLeavesBothClaudeColumnsUnmeasured() async {
        let result = await runner(claudeAvailability: .unavailable(reason: "Claude not configured")).run(cases(1))
        #expect(result.columns == [.onDevice])
        #expect(result.unmeasured["claude"] == "Claude not configured")
        #expect(result.unmeasured["claudeDeep"] == "Claude not configured")
    }

    @Test func stopsBeforeCrossingTheSpendCap() async {
        // Each prompt costs two Claude answers ($0.00045) plus three judgments ($0.001 each).
        let perPrompt = 0.00045 + 0.003
        let result = await runner(judge: FakeAnswerJudge.passing(containing: "claude", cost: 0.001), spendCap: perPrompt * 2.5).run(cases(5))
        #expect(result.cases.count == 2)
        #expect(result.stoppedAtSpendCap)
        #expect(result.spent <= perPrompt * 2.5)
    }

    @Test func resumesFromACheckpoint() async throws {
        let checkpoint = FileManager.default.temporaryDirectory.appendingPathComponent("quality-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: checkpoint) }
        await runner(checkpoint: checkpoint).run(cases(2))

        let judge = FakeAnswerJudge.passing(containing: "claude")
        let resumed = await runner(judge: judge, checkpoint: checkpoint).run(cases(3))
        #expect(resumed.cases.map(\.id) == [1, 2, 3])
        // Only the new prompt was answered and judged.
        #expect(judge.judged.count == 3)
    }

    @Test func aFailingJudgeIsRetriedThenRecorded() async throws {
        struct BrokenJudge: AnswerJudge {
            func judge(_ answer: String, to benchmarkCase: QualityBenchmark.Case) async throws -> JudgeVerdict {
                throw CancellationError()
            }
        }
        let result = await runner(judge: BrokenJudge()).run(cases(1))
        let judgments = try #require(result.cases.first?.judgments)
        #expect(judgments.allSatisfy { !$0.passes && $0.rationale.hasPrefix(QualityBenchmarkRunner.judgeErrorPrefix) })
        #expect(QualityReport(result).judgeErrors == 3)
    }
}
