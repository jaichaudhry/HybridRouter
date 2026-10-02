import Foundation
import FoundationModels
import Testing
@testable import RouterKit

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
        claude: FakeProvider = FakeProvider(route: .claude, reply: "claude reply")
    ) -> RoutedSession {
        RoutedSession(
            instructions: "You are helpful.",
            onDevice: onDevice,
            appleCloud: appleCloud,
            claude: claude,
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
        let claude = FakeProvider(route: .claude, reply: "hello from claude")
        let session = makeSession(onDevice: onDevice, claude: claude)

        let first = try await session.respond(to: "Hi", decision: .forced(.onDevice))
        let second = try await session.respond(to: "Again", decision: .forced(.claude))

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
        let claude = FakeProvider(route: .claude, reply: "Cut day two")
        let session = makeSession(onDevice: onDevice, appleCloud: appleCloud, claude: claude)

        _ = try await session.respond(to: "Trip ideas?", decision: .forced(.onDevice))
        _ = try await session.respond(to: "Plan Kyoto", decision: .forced(.appleCloud))
        _ = try await session.respond(to: "Is it realistic?", decision: .forced(.claude))
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
        _ = try await session.respond(to: "Count", decision: .forced(.onDevice)) { partials.append($0) }
        #expect(partials.last == "one two three")
        #expect(partials.count >= 2)
        #expect(zip(partials, partials.dropFirst()).allSatisfy { $1.hasPrefix($0) })
    }

    @Test func metricsCarryTheDecisionUsageAndCost() async throws {
        let usage = TokenUsage(input: 1_000_000, cachedInput: 0, output: 100_000, reasoning: 0)
        let session = makeSession(claude: FakeProvider(route: .claude, reply: "ok", usage: usage))
        let decision = RouteDecision(route: .claude, reason: "Complex reasoning", source: .classifier)

        let result = try await session.respond(to: "Think hard", decision: decision)

        #expect(result.metrics.route == .claude)
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
        let claude = FakeProvider(route: .claude, reply: "x", availability: .unavailable(reason: "Claude not configured"))
        let session = makeSession(claude: claude)

        await #expect(throws: RoutedSession.Error.routeUnavailable(.claude, reason: "Claude not configured")) {
            try await session.respond(to: "Hi", decision: .forced(.claude))
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
            try await session.respond(to: "Second", decision: .forced(.claude))
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
