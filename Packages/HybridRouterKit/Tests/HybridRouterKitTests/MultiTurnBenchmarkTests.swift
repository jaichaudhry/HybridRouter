import Foundation
import HybridRouterKit
import HybridRouterKitTesting
import Testing

@MainActor
struct MultiTurnBenchmarkTests {
    private typealias Bench = MultiTurnBenchmark

    private let costTable = CostTable(updated: "2026-10-27", source: "test", models: [:])

    private func makeSession(_ tap: CloudTap, cloud: FakeProvider = FakeProvider(route: .cloud, reply: "from cloud")) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .onDevice, reply: "from device", contextLimit: 8_192),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
            cloud: tap.wrap(cloud),
            costTable: costTable
        )
    }

    private func coordinator(_ complexity: String = "complex") -> TurnCoordinator {
        TurnCoordinator(router: Router(classifier: FakeClassifier.always(complexity)),
                        policy: EscalationPolicy(retryDelay: .zero),
                        estimator: FixedTokenEstimator(100), isOnline: { true })
    }

    private func runner(_ dataset: Bench.Dataset, complexity: String = "complex", judge: FakeAnswerJudge = .passing(containing: "from"),
                        spendCap: Double = 100, checkpoint: URL? = nil) -> MultiTurnBenchmarkRunner {
        MultiTurnBenchmarkRunner(
            dataset: dataset,
            makeSession: { _, tap in makeSession(tap) },
            makeCoordinator: { coordinator(complexity) },
            judge: judge,
            spendCap: spendCap,
            checkpoint: checkpoint,
            device: "test", classifierName: "fake", judgeModelID: "fake-judge"
        )
    }

    private static let card = "4111 1111 1111 1111"

    private static let privacyConversation = Bench.Conversation(
        id: "pr-01", group: .privacy, title: "Refund", secrets: [card],
        turns: [
            .init(prompt: "My card \(card) was charged twice.", tags: [.private]),
            .init(prompt: "Draft an email asking for a refund.", tags: [.afterPrivate]),
        ]
    )

    private static func failureConversation(count: Int) -> Bench.Conversation {
        Bench.Conversation(
            id: "fa-01", group: .failure, title: "Plan",
            faults: [.init(turn: 1, failure: .rateLimited, count: count)],
            turns: [.init(prompt: "Plan a week in Japan."), .init(prompt: "Shorter.", tags: [.followUp])]
        )
    }

    @Test func eachConversationRunsUnderEachStrategyAndEveryTurnIsGraded() async {
        let dataset = Bench.Dataset(conversations: [
            Bench.Conversation(id: "fu-01", group: .followUp, title: "Trip", turns: [
                .init(prompt: "Plan a trip to Lisbon."), .init(prompt: "Why?", tags: [.followUp]),
            ]),
            Self.failureConversation(count: 1),
        ])
        let result = await runner(dataset).run()

        #expect(result.runs.count == 4)  // 3 strategies + the failure conversation on the router only
        #expect(result.run("fa-01", .onDevice) == nil)
        let onDevice = try! #require(result.run("fu-01", .onDevice))
        #expect(onDevice.turns.allSatisfy { $0.route == .onDevice && $0.passes })
        let router = try! #require(result.run("fu-01", .router))
        #expect(router.turns.allSatisfy { $0.route == .cloud })
        #expect(result.availableRoutes == [.onDevice, .cloud])
        #expect(result.onDeviceContextSize == 8_192)

        let report = MultiTurnReport(result, dataset: dataset)
        #expect(report.strategies.map(\.strategy) == [.router, .onDevice, .claude])
        #expect(report.strategies.first { $0.strategy == .onDevice }?.onDeviceShare == 1)
        #expect(report.followUps.count == 1)
        #expect(report.followUps.stayed == 1)
    }

    @Test func privateTurnsNeverReachTheCloudModelOnTheRouter() async {
        let dataset = Bench.Dataset(conversations: [Self.privacyConversation])
        let result = await runner(dataset).run()

        let router = try! #require(result.run("pr-01", .router))
        #expect(router.turns[0].privacyReason == "card number")
        #expect(router.turns[0].route == .onDevice)
        #expect(router.turns[1].route == .onDevice)  // builds on the private turn, so stays on the phone
        #expect(router.leaks.isEmpty)
        #expect(router.cloudRequests == 0)

        // The leak check works: always-Claude sends the card on purpose, as the quality ceiling.
        #expect(result.run("pr-01", .claude)?.leaks == [Self.card])

        let report = MultiTurnReport(result, dataset: dataset)
        #expect(report.privacy.leaks == 0)
        #expect(report.privacy.flagged == 1)
        #expect(report.privacy.privateTurns == 1)
        #expect(report.privacy.afterPrivateOnCloud == 0)
    }

    @Test func aBriefCloudFailureIsRetried() async {
        let dataset = Bench.Dataset(conversations: [Self.failureConversation(count: 1)])
        let result = await runner(dataset).run()

        let turn = try! #require(result.run("fa-01", .router)?.turns.first)
        #expect(turn.faultsFired == 1)
        #expect(turn.route == .cloud)
        #expect(turn.steps.count == 2)
        #expect(turn.steps.first?.failure == FailureCause.rateLimited.label)
        #expect(result.run("fa-01", .router)?.turns[1].faultsFired == 0)

        let report = MultiTurnReport(result, dataset: dataset)
        #expect(report.failures.faultedTurns == 1)
        #expect(report.failures.answered == 1)
        #expect(report.failures.fellBack == 0)
    }

    @Test func aPersistentCloudFailureFallsBackToOnDevice() async {
        let dataset = Bench.Dataset(conversations: [Self.failureConversation(count: 2)])
        let result = await runner(dataset).run()

        let turn = try! #require(result.run("fa-01", .router)?.turns.first)
        #expect(turn.faultsFired == 2)
        #expect(turn.route == .onDevice)
        #expect(turn.text == "from device")
        #expect(MultiTurnReport(result, dataset: dataset).failures.fellBack == 1)
    }

    @Test func aFaultOnATurnThatStaysOnDeviceDoesNotFire() async {
        let dataset = Bench.Dataset(conversations: [Self.failureConversation(count: 1)])
        let result = await runner(dataset, complexity: "simple").run()

        #expect(result.run("fa-01", .router)?.turns.allSatisfy { $0.route == .onDevice && $0.faultsFired == 0 } == true)
        #expect(MultiTurnReport(result, dataset: dataset).failures.notFired == 1)
    }

    @Test func theJudgeSeesTheEarlierTurnsAndTheDocument() async {
        let dataset = Bench.Dataset(
            documents: ["lease": .init(title: "Lease", text: "Pets need a $400 deposit.")],
            conversations: [Bench.Conversation(id: "lc-01", group: .longChat, title: "Lease", turns: [
                .init(prompt: "Summarize this.", document: "lease"),
                .init(prompt: "What about pets?", criteria: "$400", tags: [.recall]),
            ])]
        )
        var seen: [QualityBenchmark.Case] = []
        let judge = FakeAnswerJudge { _, judgedCase in
            seen.append(judgedCase)
            return true
        }
        _ = await runner(dataset, judge: judge).run(only: ["lc-01"])

        let second = try! #require(seen.first { $0.id == 1 })
        #expect(second.criteria == "$400")
        #expect(second.prompt == "What about pets?")
        let conversation = try! #require(second.conversation)
        #expect(conversation.contains("Pets need a $400 deposit.\n\nSummarize this."))
        #expect(conversation.contains("Assistant:\nfrom"))
        #expect(seen.first { $0.id == 0 }?.conversation == nil)
    }

    @Test func unansweredTurnsFailWithoutBeingJudged() async {
        let dataset = Bench.Dataset(conversations: [Self.privacyConversation])
        let judge = FakeAnswerJudge.passing(containing: "from")
        let runner = MultiTurnBenchmarkRunner(
            dataset: dataset,
            makeSession: { _, tap in makeSession(tap, cloud: FakeProvider(route: .cloud, reply: "x", behavior: .timeout)) },
            makeCoordinator: { coordinator() },
            judge: judge, spendCap: 100,
            device: "test", classifierName: "fake", judgeModelID: "fake-judge"
        )
        let result = await runner.run()

        let claude = try! #require(result.run("pr-01", .claude))
        #expect(claude.turns.allSatisfy { !$0.isAnswered && !$0.passes && $0.grade == nil && $0.failure != nil })
    }

    @Test func aRunResumesFromItsCheckpoint() async throws {
        let checkpoint = FileManager.default.temporaryDirectory.appending(path: "multiturn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: checkpoint) }
        let dataset = Bench.Dataset(conversations: [Self.privacyConversation, Self.failureConversation(count: 1)])

        let first = await runner(dataset, checkpoint: checkpoint).run(only: ["pr-01"])
        #expect(first.runs.count == 3)

        let judge = FakeAnswerJudge.passing(containing: "from")
        let resumed = await runner(dataset, judge: judge, checkpoint: checkpoint).run()
        #expect(resumed.runs.count == 4)
        #expect(judge.judged.count == 2)  // only the failure conversation's two turns
    }

    @Test func theRunStopsBeforeCrossingTheSpendCap() async {
        let dataset = Bench.Dataset(conversations: [Self.privacyConversation, Self.failureConversation(count: 1)])
        let result = await runner(dataset, judge: .passing(containing: "from", cost: 1), spendCap: 3).run()

        #expect(result.stoppedAtSpendCap)
        #expect(result.runs.count == 1)
        #expect(result.spent == 2)
    }
}
