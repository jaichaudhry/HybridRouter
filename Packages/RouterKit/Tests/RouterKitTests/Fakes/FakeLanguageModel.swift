import Foundation
import FoundationModels
import Synchronization
@testable import RouterKit

/// A LanguageModel that streams a canned reply word by word and records every request,
/// so tests can drive a real LanguageModelSession without a device or network.
struct FakeLanguageModel: LanguageModel {
    typealias Executor = FakeExecutor

    let name: String
    let reply: String
    let usage: TokenUsage
    /// Pause before replying, to hold a turn open.
    let delay: Duration

    init(
        name: String,
        reply: String,
        usage: TokenUsage = TokenUsage(input: 10, cachedInput: 2, output: 5, reasoning: 0),
        delay: Duration = .zero
    ) {
        self.name = name
        self.reply = reply
        self.usage = usage
        self.delay = delay
    }

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    var executorConfiguration: FakeExecutor.Configuration {
        FakeExecutor.Configuration(name: name, reply: reply, usage: usage, delay: delay)
    }
}

struct FakeExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        let name: String
        let reply: String
        let usage: TokenUsage
        let delay: Duration
    }

    private let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: FakeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        RequestLog.shared.record(model: configuration.name, transcript: request.transcript)
        if configuration.delay > .zero {
            try await Task.sleep(for: configuration.delay)
        }
        let words = configuration.reply.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            let text = index == 0 ? String(word) : " " + word
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
        }
        let usage = configuration.usage
        await channel.send(.response(action: .updateUsage(
            input: .init(totalTokenCount: usage.input, cachedTokenCount: usage.cachedInput),
            output: .init(totalTokenCount: usage.output, reasoningTokenCount: usage.reasoning ?? 0)
        )))
    }
}

/// Requests each fake model received, keyed by model name.
final class RequestLog: Sendable {
    static let shared = RequestLog()

    private let requests = Mutex<[String: [Transcript]]>([:])

    func record(model: String, transcript: Transcript) {
        requests.withLock { $0[model, default: []].append(transcript) }
    }

    func transcripts(for model: String) -> [Transcript] {
        requests.withLock { $0[model] ?? [] }
    }
}

/// A provider wrapping a fake model, with controllable availability.
struct FakeProvider: ModelProvider {
    let route: Route
    let modelID: String
    let fake: FakeLanguageModel
    var availability: ProviderAvailability

    init(
        route: Route,
        reply: String,
        availability: ProviderAvailability = .available,
        usage: TokenUsage = TokenUsage(input: 10, cachedInput: 2, output: 5, reasoning: 0),
        delay: Duration = .zero
    ) {
        self.route = route
        // Unique per test so the shared request log never mixes tests.
        let name = "\(route.rawValue)-\(UUID().uuidString)"
        self.modelID = route == .claude ? "claude-sonnet-5-5" : "apple-on-device"
        self.fake = FakeLanguageModel(name: name, reply: reply, usage: usage, delay: delay)
        self.availability = availability
    }

    var model: any LanguageModel { fake }

    var requests: [Transcript] { RequestLog.shared.transcripts(for: fake.name) }
}
