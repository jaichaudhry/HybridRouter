import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

@MainActor
struct RoutedSessionTests {
    private let costTable = CostTable(
        updated: "2026-10-02",
        source: "test",
        models: [
            "apple-on-device": .init(input: 0, cachedInput: 0, output: 0),
            "claude-sonnet-5-5": .init(input: 2, cachedInput: 0.2, output: 10),
        ]
    )

    private func makeSession(
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "on-device reply"),
        appleCloud: FakeProvider = FakeProvider(route: .appleCloud, reply: "cloud reply"),
        cloud: FakeProvider = FakeProvider(route: .cloud, reply: "claude reply")
    ) -> RoutedSession {
        RoutedSession(
            instructions: "You are helpful.",
            onDevice: onDevice,
            appleCloud: appleCloud,
            cloud: cloud,
            costTable: costTable
        )
    }

    private func texts(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            switch entry {
            case .prompt(let prompt): prompt.segments.text
            case .response(let response): response.segments.text
            default: nil
            }
        }
    }

    @Test func eachTurnRunsOnItsRoute() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "hello from device")
        let claude = FakeProvider(route: .cloud, reply: "hello from claude")
        let session = makeSession(onDevice: onDevice, cloud: claude)

        let first = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        let second = try await session.respond(to: "Again", decision: .forced(.cloud))

        #expect(first.text == "hello from device")
        #expect(second.text == "hello from claude")
        #expect(onDevice.requests.count == 1)
        #expect(claude.requests.count == 1)
    }

    /// M1 acceptance: a conversation hops on-device → Apple Cloud → Claude → on-device,
    /// and every model sees the turns the others handled.
    @Test func historyCarriesAcrossRouteSwitches() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "Seattle ideas")
        let appleCloud = FakeProvider(route: .appleCloud, reply: "Kyoto itinerary")
        let claude = FakeProvider(route: .cloud, reply: "Cut day two")
        let session = makeSession(onDevice: onDevice, appleCloud: appleCloud, cloud: claude)

        _ = try await session.respond(to: "Trip ideas?", decision: .forced(.onDevice))
        _ = try await session.respond(to: "Plan Kyoto", decision: .forced(.appleCloud))
        _ = try await session.respond(to: "Is it realistic?", decision: .forced(.cloud))
        _ = try await session.respond(to: "Text my partner", decision: .forced(.onDevice))

        let cloudSaw = try #require(appleCloud.requests.last)
        #expect(texts(in: cloudSaw) == ["Trip ideas?", "Seattle ideas", "Plan Kyoto"])

        let claudeSaw = try #require(claude.requests.last)
        #expect(texts(in: claudeSaw) == ["Trip ideas?", "Seattle ideas", "Plan Kyoto", "Kyoto itinerary", "Is it realistic?"])

        let backOnDevice = try #require(onDevice.requests.last)
        #expect(texts(in: backOnDevice) == [
            "Trip ideas?", "Seattle ideas", "Plan Kyoto", "Kyoto itinerary",
            "Is it realistic?", "Cut day two", "Text my partner",
        ])
    }

    @Test func partialTextStreamsCumulatively() async throws {
        let session = makeSession(onDevice: FakeProvider(route: .onDevice, reply: "one two three"))
        var partials: [String] = []
        _ = try await session.respond(to: "Count", decision: .forced(.onDevice)) { partials.append($0.text) }
        #expect(partials.last == "one two three")
        #expect(partials.count >= 2)
        #expect(zip(partials, partials.dropFirst()).allSatisfy { $1.hasPrefix($0) })
    }

    @Test func metricsCarryTheDecisionUsageAndCost() async throws {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 0, output: 100_000, reasoning: 0)
        let session = makeSession(cloud: FakeProvider(route: .cloud, reply: "ok", usage: usage))
        let decision = RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier)

        let result = try await session.respond(to: "Think hard", decision: decision)

        #expect(result.metrics.route == .cloud)
        #expect(result.metrics.reason == "Complex reasoning")
        #expect(result.metrics.source == "classifier")
        #expect(result.metrics.modelID == "claude-sonnet-5-5")
        #expect(result.metrics.usage.input == 1_000_000)
        #expect(result.metrics.usage.output == 100_000)
        #expect(result.metrics.usage.reasoning == nil)
        #expect(abs((result.metrics.estimatedCost ?? 0) - 3.0) < 0.000_001)
        #expect(result.metrics.timeToFirstToken != nil)
        #expect(result.metrics.totalLatency >= (result.metrics.timeToFirstToken ?? 0))
    }

    @Test func usageIsPerTurnNotCumulative() async throws {
        let session = makeSession()
        _ = try await session.respond(to: "One", decision: .forced(.onDevice))
        let second = try await session.respond(to: "Two", decision: .forced(.onDevice))
        #expect(second.metrics.usage.input == 10)
        #expect(second.metrics.usage.output == 5)
    }

    @Test func unavailableRouteIsRefusedWithItsReason() async throws {
        let claude = FakeProvider(route: .cloud, reply: "x", availability: .unavailable(reason: "Claude not configured"))
        let session = makeSession(cloud: claude)

        await #expect(throws: RoutedSession.Error.routeUnavailable(.cloud, reason: "Claude not configured")) {
            try await session.respond(to: "Hi", decision: .forced(.cloud))
        }
        #expect(claude.requests.isEmpty)
        #expect(session.transcript.count == 1) // instructions only
    }

    @Test func overlappingTurnsAreRejected() async throws {
        let slow = FakeProvider(route: .onDevice, reply: "slow", delay: .milliseconds(300))
        let session = makeSession(onDevice: slow)

        let first = Task { try await session.respond(to: "First", decision: .forced(.onDevice)) }
        while !session.isResponding { await Task.yield() }

        await #expect(throws: RoutedSession.Error.busy) {
            try await session.respond(to: "Second", decision: .forced(.cloud))
        }
        #expect(try await first.value.text == "slow")
        #expect(!session.isResponding)
    }
}

private extension Array where Element == Transcript.Segment {
    var text: String {
        compactMap { segment in
            if case .text(let text) = segment { text.content } else { nil }
        }.joined()
    }
}

extension RoutedSessionTests {
    @Test func prewarmingThenRespondingUsesTheDecidedRoute() async throws {
        let claude = FakeProvider(route: .cloud, reply: "claude")
        let session = makeSession(cloud: claude)
        session.prewarm(.cloud)
        let result = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        #expect(result.text == "on-device reply")
        #expect(claude.requests.isEmpty)
    }

    @Test func prewarmingAnUnavailableRouteIsIgnored() async throws {
        let session = makeSession(cloud: FakeProvider(route: .cloud, reply: "x", availability: .unavailable(reason: "off")))
        session.prewarm(.cloud)
        let result = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        #expect(result.text == "on-device reply")
    }
}

extension RoutedSessionTests {
    @Generable
    struct Place: Equatable {
        var name: String
        var days: Int
    }

    @Test func schemaRepliesAreStructured() async throws {
        let session = makeSession(appleCloud: FakeProvider(route: .appleCloud, reply: #"{"name": "Kyoto", "days": 3}"#))
        var partials = 0
        let result = try await session.respond(
            to: "Plan Kyoto",
            decision: .forced(.appleCloud),
            schema: Place.generationSchema
        ) { _ in partials += 1 }

        guard case .structured(let content) = result.content else {
            Issue.record("Expected structured content")
            return
        }
        #expect(try Place(content) == Place(name: "Kyoto", days: 3))
        #expect(partials > 0)
        #expect(!result.content.isEmpty)
    }

    @Test func discardingTheLastTurnRemovesItsPromptAndReply() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "kept")
        let session = makeSession(onDevice: onDevice)
        _ = try await session.respond(to: "Keep me", decision: .forced(.onDevice))
        _ = try await session.respond(to: "Drop me", decision: .forced(.onDevice))

        session.discardLastTurn()
        _ = try await session.respond(to: "Next", decision: .forced(.onDevice))

        let saw = try #require(onDevice.requests.last)
        #expect(texts(in: saw) == ["Keep me", "kept", "Next"])
    }

    @Test func emptyContentIsDetected() {
        #expect(TurnContent.text("  \n").isEmpty)
        #expect(!TurnContent.text("hi").isEmpty)
    }
}

extension RoutedSessionTests {
    struct EchoTool: Tool {
        let name = "echo"
        let description = "Repeats its input."

        @Generable
        struct Arguments {
            var text: String
        }

        func call(arguments: Arguments) async throws -> String {
            arguments.text
        }
    }

    @Test func scenarioToolsAreOfferedOnEveryRoute() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "a")
        let claude = FakeProvider(route: .cloud, reply: "b")
        let session = RoutedSession(
            instructions: "Be brief.",
            tools: [EchoTool()],
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "c"),
            cloud: claude,
            costTable: costTable
        )
        _ = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        _ = try await session.respond(to: "Again", decision: .forced(.cloud))
        #expect(onDevice.offeredTools == ["echo"])
        #expect(claude.offeredTools == ["echo"])
    }
}

extension RoutedSessionTests {
    @Test func stepsFromAStandInAreMarkedSimulated() async throws {
        var standIn = FakeProvider(route: .appleCloud, reply: "simulated")
        standIn.isSimulated = true
        let session = makeSession(appleCloud: standIn)
        let simulated = try await session.respond(to: "Plan", decision: .forced(.appleCloud))
        let real = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        #expect(simulated.metrics.isSimulated)
        #expect(!real.metrics.isSimulated)
    }
}
