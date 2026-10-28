import Foundation
import FoundationModels
import HybridRouterKit
import Testing

/// Checks multiturn_benchmark.json before any paid run: the set is complete, and the privacy
/// guard keeps exactly the turns tagged private, so the privacy numbers measure routing.
struct MultiTurnDatasetTests {
    private static let dataset: MultiTurnBenchmark.Dataset? = Bundle.module
        .url(forResource: "multiturn_benchmark", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? MultiTurnBenchmark.Dataset.load($0) }

    @Test func theSetHas36ConversationsWithAQuarterHeldOut() throws {
        let dataset = try #require(Self.dataset)
        #expect(dataset.conversations.count == 36)
        #expect(Set(dataset.conversations.map(\.id)).count == 36)
        #expect(dataset.conversations.filter { $0.split == "heldout" }.count == 9)
        let groups = Dictionary(grouping: dataset.conversations, by: \.group).mapValues(\.count)
        #expect(groups == [.followUp: 12, .privacy: 8, .longChat: 8, .failure: 8])
        #expect(dataset.conversations.allSatisfy { (4...6).contains($0.turns.count) })
    }

    @Test func documentsAndFaultsPointAtRealThings() throws {
        let dataset = try #require(Self.dataset)
        for conversation in dataset.conversations {
            for turn in conversation.turns {
                if let key = turn.document { #expect(dataset.documents[key] != nil, "\(conversation.id): \(key)") }
            }
            for fault in conversation.faults ?? [] {
                #expect((1...conversation.turns.count).contains(fault.turn), "\(conversation.id)")
            }
            #expect((conversation.faults ?? []).isEmpty == (conversation.group != .failure), "\(conversation.id)")
        }
        #expect(dataset.conversations.filter { $0.group == .longChat }.allSatisfy { $0.turns.first?.document != nil })
    }

    @Test func thePrivacyGuardFlagsExactlyThePrivateTurns() throws {
        let dataset = try #require(Self.dataset)
        let privacyGuard = PrivacyGuard()
        for conversation in dataset.conversations {
            for (index, turn) in conversation.turns.enumerated() {
                let flagged = privacyGuard.assess(dataset.message(for: turn), markedPrivate: turn.markedPrivate ?? false) != nil
                #expect(flagged == turn.has(.private), "\(conversation.id) turn \(index + 1): \(turn.prompt.prefix(60))")
            }
        }
    }

    @Test func secretsComeFromThePrivateTurns() throws {
        let dataset = try #require(Self.dataset)
        for conversation in dataset.conversations where conversation.group == .privacy {
            let secrets = try #require(conversation.secrets, "\(conversation.id)")
            let privateText = conversation.turns.filter { $0.has(.private) }.map(\.prompt).joined(separator: "\n")
            #expect(!secrets.isEmpty)
            for secret in secrets {
                #expect(privateText.localizedCaseInsensitiveContains(secret), "\(conversation.id): \(secret)")
            }
            // The rest of the conversation must not repeat a secret, or a leak couldn't be told apart.
            let otherText = conversation.turns.filter { !$0.has(.private) }.map(\.prompt).joined(separator: "\n")
            for secret in secrets {
                #expect(!otherText.localizedCaseInsensitiveContains(secret), "\(conversation.id): \(secret)")
            }
        }
    }

    @Test func everyTurnHasAnAnswerKeyExceptOpenEndedOnes() throws {
        let dataset = try #require(Self.dataset)
        let turns = dataset.conversations.flatMap(\.turns)
        #expect(turns.allSatisfy { $0.criteria != nil })
        #expect(turns.filter { $0.has(.recall) }.count >= 16)
    }

    /// Writes the Markdown report for a saved run next to it, without calling any model.
    ///
    ///     HR_MULTITURN_RESULTS=Evals/results/2026-10-27-iphone-multiturn.json \
    ///         swift test --package-path Evals --filter multiTurnReport
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HR_MULTITURN_RESULTS"] != nil, "Set HR_MULTITURN_RESULTS to a results JSON"))
    func multiTurnReport() throws {
        let dataset = try #require(Self.dataset)
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = try #require(ProcessInfo.processInfo.environment["HR_MULTITURN_RESULTS"])
        let file = path.hasPrefix("/") ? URL(filePath: path) : repo.appending(path: path)
        let run = try MultiTurnBenchmark.RunResult.load(Data(contentsOf: file))
        let sections = [(nil, "All conversations"), ("heldout", "Held-out"), ("tuning", "Tuning")].compactMap { split, title in
            let report = MultiTurnReport(run, dataset: dataset, split: split)
            return report.conversations > 0 ? report.markdown(title: title) : nil
        }
        let header = """
            # Multi-turn benchmark on \(run.device)

            \(run.runs.count) conversation runs, \(String(format: "$%.2f", run.spent)) spent. Router: \(run.classifier). \
            Cloud model: \(run.cloudModelID). On-device context: \(run.onDeviceContextSize.map { "\($0) tokens" } ?? "unknown"). \
            Judge: \(run.judgeModelID).
            """
        let markdown = ([header] + sections).joined(separator: "\n\n")
        try markdown.write(to: file.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
        #expect(run.runs.count > 0)
    }
}

/// The benchmark's CloudTap in front of a real model, not a fake: requests are recorded and an
/// injected fault surfaces as the real error. Free: it uses the on-device model.
@MainActor
struct CloudTapLiveTests {
    @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
    func theTapRecordsRequestsAndInjectsFaultsOnARealModel() async throws {
        let tap = CloudTap()
        let session = RoutedSession(
            instructions: "Answer in one short sentence.",
            onDevice: tap.wrap(OnDeviceProvider()),
            appleCloud: AppleCloudProvider(isEnabled: false),
            cloud: ClaudeProvider(auth: .apiKey("unused"), tier: .standard),
            costTable: CostTable(updated: "", source: "", models: [:])
        )
        let reply = try await session.respond(to: "What color is the sky on a clear day?", decision: .forced(.onDevice))
        #expect(!reply.text.isEmpty)
        #expect(tap.requests.count == 1)
        #expect(tap.requests[0].contains("What color is the sky"))

        tap.arm([.init(turn: 1, failure: .timeout)])
        await #expect(throws: RoutedSession.StepFailure.self) {
            _ = try await session.respond(to: "And at sunset?", decision: .forced(.onDevice))
        }
        #expect(tap.disarm() == 1)
    }
}
