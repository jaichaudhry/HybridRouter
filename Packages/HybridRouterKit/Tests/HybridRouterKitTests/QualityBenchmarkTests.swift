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
    private static func result(_ id: Int, onDevice: Bool, cloud: Bool, router: Route) -> QualityBenchmark.CaseResult {
        .init(
            case: benchmarkCase(id),
            routerRoute: router, routerReason: nil, routerLatency: 0.5,
            answers: [answer(.onDevice, cost: 0), answer(.claude, cost: 0.01)],
            judgments: [
                .init(column: .onDevice, passes: onDevice, score: onDevice ? 5 : 1, rationale: "", cost: 0.001),
                .init(column: .claude, passes: cloud, score: cloud ? 5 : 1, rationale: "", cost: 0.001),
            ]
        )
    }

    private static let run: QualityBenchmark.RunResult = {
        var run = QualityBenchmark.RunResult(
            device: "test", classifier: "fake", judgeModelID: "judge", startedAt: Date(timeIntervalSince1970: 0),
            columns: [.onDevice, .claude], unmeasured: ["appleCloud": "No entitlement"]
        )
        run.cases = [
            result(1, onDevice: true, cloud: true, router: .onDevice),   // matched
            result(2, onDevice: false, cloud: true, router: .onDevice),  // under-routed
            result(3, onDevice: true, cloud: true, router: .cloud),     // over-routed
            result(4, onDevice: false, cloud: false, router: .cloud),   // unsolved
        ]
        return run
    }()

    @Test func strategiesScoreQualityAndCost() throws {
        let report = QualityReport(Self.run)
        let router = try #require(report.result(for: .router))
        #expect(router.passRate == 0.5)
        #expect(abs(router.costPer100 - 0.5) < 1e-9)
        #expect(router.onDeviceShare == 0.5)

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
        #expect(random.onDeviceShare == 0.5)
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
        run.cases.append(Self.result(5, onDevice: true, cloud: true, router: .onDevice))
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
        museAvailability: ProviderAvailability = .unavailable(reason: "Muse Wonder not configured"),
        appleCloudIsReal: Bool = false,
        appleCloudBehavior: FakeBehavior = .reply,
        spendCap: Double = 100,
        checkpoint: URL? = nil
    ) -> QualityBenchmarkRunner {
        let costTable = costTable
        return QualityBenchmarkRunner(
            makeSession: { column in
                var appleCloud = FakeProvider(route: .appleCloud, reply: "cloud answer", behavior: appleCloudBehavior)
                appleCloud.isSimulated = !appleCloudIsReal
                let reply = switch column {
                case .claudeDeep: "claude deep answer"
                case .museWonder: "muse answer"
                default: "claude answer"
                }
                var claude = FakeProvider(route: .cloud, reply: reply)
                claude.availability = column == .museWonder ? museAvailability : claudeAvailability
                return RoutedSession(
                    instructions: "Be brief.",
                    onDevice: FakeProvider(route: .onDevice, reply: "device answer"),
                    appleCloud: appleCloud,
                    cloud: claude,
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

    @Test func addsAColumnWithoutReansweringTheOthers() async throws {
        let original = await runner().run(cases(2))
        #expect(original.unmeasured["museWonder"] == "Muse Wonder not configured")

        let judge = FakeAnswerJudge.passing(containing: "muse")
        let extended = await runner(judge: judge, museAvailability: .available).addColumn(.museWonder, to: original)
        #expect(extended.columns == [.onDevice, .claude, .claudeDeep, .museWonder])
        #expect(extended.unmeasured["museWonder"] == nil)
        #expect(judge.judged == ["muse answer", "muse answer"])
        #expect(extended.cases.map(\.id) == [1, 2])
        let first = try #require(extended.cases.first)
        #expect(first.answers.count == 4)
        #expect(first.passes(.museWonder))
        #expect(first.answer(.claude)?.text == "claude answer")

        let muse = try #require(QualityReport(extended).result(for: .alwaysMuseWonder))
        #expect(muse.passRate == 1)
        // Every Muse Wonder answer comes from the cloud, so nothing stays on the phone.
        #expect(muse.onDeviceShare == 0)
        // The router and the oracle still choose among the routing rungs only.
        #expect(QualityReport(extended).result(for: .oracle) == QualityReport(original).result(for: .oracle))
    }

    @Test func addingAColumnResumesFromACheckpoint() async throws {
        let checkpoint = FileManager.default.temporaryDirectory.appendingPathComponent("quality-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: checkpoint) }
        let original = await runner().run(cases(3))
        // Stop after the first prompt by capping spend at one prompt's worth.
        let first = await runner(judge: FakeAnswerJudge.passing(containing: "muse", cost: 0.01), museAvailability: .available,
                                 spendCap: 0.015, checkpoint: checkpoint).addColumn(.museWonder, to: original, concurrency: 1)
        #expect(first.stoppedAtSpendCap)
        #expect(first.cases.filter { $0.answer(.museWonder) != nil }.count == 1)

        let judge = FakeAnswerJudge.passing(containing: "muse")
        let resumed = await runner(judge: judge, museAvailability: .available, checkpoint: checkpoint).addColumn(.museWonder, to: original)
        #expect(judge.judged.count == 2)
        #expect(resumed.cases.allSatisfy { $0.answer(.museWonder) != nil })
    }

    @Test func addingAppleCloudRecomputesTheRoutersChoices() async throws {
        // "moderate" goes to Apple Cloud; without it, the router moved those turns up to Claude.
        let original = await runner(classifier: .always("moderate")).run(cases(2))
        #expect(original.cases.allSatisfy { $0.routerRoute == .cloud && $0.routerReason?.hasSuffix("(Apple Cloud unavailable)") == true })

        let judge = FakeAnswerJudge.passing(containing: "cloud")
        let extended = await runner(judge: judge, appleCloudIsReal: true).addColumn(.appleCloud, to: original)
        #expect(extended.columns == [.onDevice, .appleCloud, .claude, .claudeDeep])
        #expect(extended.unmeasured["appleCloud"] == nil)
        #expect(extended.cases.allSatisfy { $0.routerRoute == .appleCloud && $0.routerReason?.contains("unavailable") == false })
        #expect(extended.routerNote != nil)
        #expect(judge.judged == ["cloud answer", "cloud answer"])

        let report = QualityReport(extended)
        #expect(report.result(for: .alwaysAppleCloud)?.passRate == 1)
        // The router now picks Apple Cloud, whose answers passed, at no cost.
        #expect(report.result(for: .router)?.passRate == 1)
        #expect(report.result(for: .router)?.costPer100 == 0)
        // Apple Cloud's answers passed and the on-device ones didn't, so nothing stays on-device.
        #expect(report.result(for: .oracle)?.onDeviceShare == 0)
    }

    @Test func routingWithAppleCloudOnlyMovesTurnsItWouldHaveTaken() {
        func result(_ route: Route, _ reason: String) -> QualityBenchmark.CaseResult {
            .init(case: cases(1)[0], routerRoute: route, routerReason: reason, routerLatency: nil, answers: [], judgments: [])
        }
        let moved = result(.cloud, "Multi-step summary (Apple Cloud unavailable)").routedWithAppleCloud()
        #expect(moved.routerRoute == .appleCloud)
        #expect(moved.routerReason == "Multi-step summary")
        #expect(result(.cloud, "Couldn't classify (timed out), so using a mid-size model").routedWithAppleCloud().routerRoute == .appleCloud)
        #expect(result(.cloud, "Complex reasoning").routedWithAppleCloud().routerRoute == .cloud)
        #expect(result(.onDevice, "Quick conversation").routedWithAppleCloud().routerRoute == .onDevice)
    }

    @Test func aSimulatedOrMissingColumnIsNotAdded() async {
        let original = await runner().run(cases(1))
        let simulated = await runner().addColumn(.appleCloud, to: original)
        #expect(!simulated.columns.contains(.appleCloud))
        let missing = await runner().addColumn(.museWonder, to: original)
        #expect(!missing.columns.contains(.museWonder))
    }

    @Test func aRateLimitStopsTheRunAndLeavesPromptsPending() async throws {
        let original = await runner().run(cases(3))
        let judge = FakeAnswerJudge.passing(containing: "cloud")
        let stopped = await runner(judge: judge, appleCloudIsReal: true, appleCloudBehavior: .rateLimited)
            .addColumn(.appleCloud, to: original, concurrency: 1)
        #expect(stopped.stoppedAtRateLimit == true)
        #expect(stopped.cases.allSatisfy { $0.answer(.appleCloud) == nil })
        #expect(judge.judged.isEmpty)
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
        #expect(result.cases.first?.routerRoute == .cloud)
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

/// Replaying routing over saved answers, and comparing two routings.
@MainActor
struct QualityReplayTests {
    private let costTable = CostTable(updated: "test", source: "test", models: [
        "apple-on-device": .init(input: 0, cachedInput: 0, output: 0),
        "claude-sonnet-5-5": .init(input: 15, cachedInput: 15, output: 15),
    ])

    private func run(_ classifier: FakeClassifier, prompts: Int = 4) async -> QualityBenchmark.RunResult {
        let costTable = costTable
        let runner = QualityBenchmarkRunner(
            makeSession: { _ in
                RoutedSession(instructions: "", onDevice: FakeProvider(route: .onDevice, reply: "device answer"),
                              appleCloud: FakeProvider(route: .appleCloud, reply: "", availability: .unavailable(reason: "off")),
                              cloud: FakeProvider(route: .cloud, reply: "claude answer"), costTable: costTable)
            },
            // On-device passes only for prompts 1 and 2.
            judge: FakeAnswerJudge { answer, benchmarkCase in answer.hasPrefix("claude") || benchmarkCase.id <= 2 },
            classifier: classifier, spendCap: 100, device: "test", classifierName: "fake", judgeModelID: "judge",
            only: [.onDevice, .claude]
        )
        let cases = (1...prompts).map { QualityBenchmark.Case(id: $0, split: "heldout", group: "chat", task: "chat", difficulty: "easy", prompt: "Question \($0)") }
        return await runner.run(cases)
    }

    @Test func onlyTheChosenColumnsAreMeasured() async {
        let result = await run(.always("complex"))
        #expect(result.columns == [.onDevice, .claude])
        #expect(result.unmeasured["claudeDeep"] == "Not part of this run")
    }

    @Test func replayingChangesOnlyTheRoutersChoices() async throws {
        let original = await run(.always("complex"))
        let replayed = await QualityReplay.reroute(original, with: Router(classifier: FakeClassifier.always("simple")))
        #expect(replayed.cases.allSatisfy { $0.routerRoute == .onDevice })
        #expect(replayed.cases.map { $0.answers.map(\.text) } == original.cases.map { $0.answers.map(\.text) })
        #expect(replayed.routerNote != nil)
    }

    @Test func comparisonsArePairedAndReproducible() async throws {
        // Everything to Claude passes all four; everything on-device passes two, at no cost.
        let cloud = await run(.always("complex"))
        let device = await QualityReplay.reroute(cloud, with: Router(classifier: FakeClassifier.always("simple")))
        let comparison = try #require(QualityReplay.compare(device, to: cloud))
        #expect(comparison.count == 4)
        #expect(comparison.changedRoutes == 4)
        #expect(abs(comparison.passDelta - -50) < 1e-9)
        #expect(abs(comparison.costChange - -1) < 1e-9)
        #expect(comparison.passInterval.contains(-50))
        #expect(QualityReplay.compare(device, to: cloud) == comparison)
        #expect(comparison.summary.hasPrefix("-50.0 points"))

        let same = try #require(QualityReplay.compare(cloud, to: cloud))
        #expect(same.passDelta == 0 && same.passInterval == 0...0 && same.changedRoutes == 0)
    }

    @Test func replayCanTakeOneSplit() async {
        var original = await run(.always("complex"))
        original.cases[0] = QualityBenchmark.CaseResult(
            case: .init(id: 1, split: "tuning", group: "chat", task: "chat", difficulty: "easy", prompt: "Question 1"),
            routerRoute: .cloud, routerReason: nil, routerLatency: nil, answers: original.cases[0].answers, judgments: original.cases[0].judgments)
        let replayed = await QualityReplay.reroute(original, with: Router(classifier: FakeClassifier.always("simple")), split: "heldout")
        #expect(replayed.cases.map(\.id) == [2, 3, 4])
    }
}
