import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

@MainActor
struct PrivateHistoryTests {
    private func texts(_ transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            let segments: [Transcript.Segment]
            switch entry {
            case .prompt(let prompt): segments = prompt.segments
            case .response(let response): segments = response.segments
            default: return nil
            }
            return segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }.joined()
        }
    }

    private func session(onDevice: FakeProvider, claude: FakeProvider) -> RoutedSession {
        RoutedSession(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            claude: claude,
            costTable: CostTable(updated: "", source: "", models: [:])
        )
    }

    @Test func claudeSeesPlaceholdersForEarlierPrivateTurns() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "Noted your number")
        let claude = FakeProvider(route: .claude, reply: "Here's a plan")
        let routed = session(onDevice: onDevice, claude: claude)

        _ = try await routed.respond(to: "My number is 206-555-0143", decision: .forced(.onDevice), isPrivate: true)
        _ = try await routed.respond(to: "Plan a trip to Kyoto", decision: .forced(.claude))
        _ = try await routed.respond(to: "Thanks", decision: .forced(.onDevice))

        let claudeSaw = try #require(claude.requests.last)
        #expect(texts(claudeSaw) == [HistoryPolicy.withheldPrompt, HistoryPolicy.withheldReply, "Plan a trip to Kyoto"])
        #expect(!texts(claudeSaw).joined().contains("555"))

        // The private turn stays intact for on-device models.
        let onDeviceSaw = try #require(onDevice.requests.last)
        #expect(texts(onDeviceSaw).contains("My number is 206-555-0143"))
        #expect(texts(onDeviceSaw).contains("Noted your number"))
    }

    @Test func nonPrivateHistoryIsUntouched() async throws {
        let claude = FakeProvider(route: .claude, reply: "ok")
        let routed = session(onDevice: FakeProvider(route: .onDevice, reply: "hi"), claude: claude)
        _ = try await routed.respond(to: "Hello", decision: .forced(.onDevice))
        _ = try await routed.respond(to: "Plan Kyoto", decision: .forced(.claude))
        #expect(texts(try #require(claude.requests.last)) == ["Hello", "hi", "Plan Kyoto"])
    }

    @Test func coordinatorMarksDetectedPrivacyAndClaudeLaterSeesPlaceholders() async throws {
        let claude = FakeProvider(route: .claude, reply: "advice")
        let routed = session(onDevice: FakeProvider(route: .onDevice, reply: "saved"), claude: claude)
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("complex")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })

        let first = await coordinator.run(.init(prompt: "Card 4111 1111 1111 1111", privacyReason: "card number"), in: routed)
        #expect(first.decision?.route == .onDevice)
        #expect(claude.requests.isEmpty)

        let second = await coordinator.run(.init(prompt: "Which offer should I take?"), in: routed)
        #expect(second.decision?.route == .claude)
        #expect(!texts(try #require(claude.requests.last)).joined().contains("4111"))
    }

    @Test func toolActivityInPrivateTurnsIsDropped() {
        let promptID = "p1"
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(id: promptID, segments: [.text(.init(content: "Read my receipt"))])),
            .toolCalls(Transcript.ToolCalls([])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "Total $42"))])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "Next"))])),
        ]
        let withheld = HistoryPolicy.withholdPrivateTurns(entries, privatePromptIDs: [promptID])
        #expect(withheld.count == 3)
        #expect(!withheld.contains { if case .toolCalls = $0 { true } else { false } })
    }

    @Test func turnsAfterAPrivateOneOnAppleRoutesAreWithheldToo() async throws {
        let onDevice = FakeProvider(route: .onDevice, reply: "Your number is 206-555-0143")
        let claude = FakeProvider(route: .claude, reply: "plan")
        let routed = session(onDevice: onDevice, claude: claude)

        _ = try await routed.respond(to: "My number is 206-555-0143", decision: .forced(.onDevice), isPrivate: true)
        _ = try await routed.respond(to: "Why?", decision: .forced(.onDevice))  // repeats the number
        _ = try await routed.respond(to: "Plan Kyoto", decision: .forced(.claude))
        _ = try await routed.respond(to: "And Osaka?", decision: .forced(.claude))

        let claudeSaw = try #require(claude.requests.last)
        #expect(!texts(claudeSaw).joined().contains("555"))
        // Claude's own earlier turn is kept.
        #expect(texts(claudeSaw).contains("Plan Kyoto"))
        #expect(texts(claudeSaw).contains("plan"))
    }

    @Test func aRebuiltSessionKeepsItsPrivateTurns() async throws {
        let first = session(onDevice: FakeProvider(route: .onDevice, reply: "ok"), claude: FakeProvider(route: .claude, reply: "x"))
        _ = try await first.respond(to: "SSN 123-45-6789", decision: .forced(.onDevice), isPrivate: true)
        let claude = FakeProvider(route: .claude, reply: "y")
        let rebuilt = RoutedSession(
            instructions: "Be brief.",
            onDevice: FakeProvider(route: .onDevice, reply: "ok"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"),
            claude: claude,
            costTable: CostTable(updated: "", source: "", models: [:]),
            history: Array(first.transcript),
            privatePromptIDs: first.privatePromptIDs
        )
        _ = try await rebuilt.respond(to: "Plan Kyoto", decision: .forced(.claude))
        #expect(!texts(try #require(claude.requests.last)).joined().contains("123-45-6789"))
    }
}
