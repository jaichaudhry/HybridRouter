import Foundation
import FoundationModels
import Synchronization
import RouterKit

/// Test doubles for RouterKit. Not for production use.

/// How a fake model responds.
public enum FakeBehavior: Hashable, Sendable {
    case reply
    /// Returns normally with no text, like a Claude refusal.
    case empty
    case timeout
    case contextExceeded
}

/// A LanguageModel that streams a canned reply word by word and records every request,
/// so tests can drive a real LanguageModelSession without a device or network.
public struct FakeLanguageModel: LanguageModel {
    public typealias Executor = FakeExecutor

    public let name: String
    public let reply: String
    public let usage: TokenUsage
    /// Pause before replying, to hold a turn open.
    public let delay: Duration
    public let behavior: FakeBehavior

    public init(
        name: String,
        reply: String,
        usage: TokenUsage = TokenUsage(input: 10, cachedInput: 2, output: 5, reasoning: 0),
        delay: Duration = .zero,
        behavior: FakeBehavior = .reply
    ) {
        self.name = name
        self.reply = reply
        self.usage = usage
        self.delay = delay
        self.behavior = behavior
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .guidedGeneration, .vision]) }

    public var executorConfiguration: FakeExecutor.Configuration {
        FakeExecutor.Configuration(name: name, reply: reply, usage: usage, delay: delay, behavior: behavior)
    }
}

public struct FakeExecutor: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        let name: String
        let reply: String
        let usage: TokenUsage
        let delay: Duration
        let behavior: FakeBehavior
    }

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: FakeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        RequestLog.shared.record(
            model: configuration.name,
            transcript: request.transcript,
            toolNames: request.enabledToolDefinitions.map(\.name)
        )
        if configuration.delay > .zero {
            try await Task.sleep(for: configuration.delay)
        }
        switch configuration.behavior {
        case .reply, .empty:
            break
        case .timeout:
            throw LanguageModelError.timeout(.init(debugDescription: "fake timeout"))
        case .contextExceeded:
            throw LanguageModelError.contextSizeExceeded(.init(contextSize: 10, tokenCount: 20, debugDescription: "fake"))
        }
        let reply = configuration.behavior == .empty ? "" : configuration.reply
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
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
public final class RequestLog: Sendable {
    public static let shared = RequestLog()

    private let requests = Mutex<[String: [Transcript]]>([:])
    private let tools = Mutex<[String: [String]]>([:])

    public func record(model: String, transcript: Transcript, toolNames: [String] = []) {
        requests.withLock { $0[model, default: []].append(transcript) }
        tools.withLock { $0[model] = toolNames }
    }

    /// Tool names offered to the model on its latest request.
    public func toolNames(for model: String) -> [String] {
        tools.withLock { $0[model] ?? [] }
    }

    public func transcripts(for model: String) -> [Transcript] {
        requests.withLock { $0[model] ?? [] }
    }
}

/// A provider wrapping a fake model, with controllable availability.
public struct FakeProvider: ModelProvider {
    public let route: Route
    public let modelID: String
    public let fake: FakeLanguageModel
    public var availability: ProviderAvailability
    public var contextLimit: Int?
    public var maximumResponseTokens: Int?
    public var isSimulated = false

    public init(
        route: Route,
        reply: String,
        availability: ProviderAvailability = .available,
        usage: TokenUsage = TokenUsage(input: 10, cachedInput: 2, output: 5, reasoning: 0),
        delay: Duration = .zero,
        contextLimit: Int? = nil,
        maximumResponseTokens: Int? = nil,
        behavior: FakeBehavior = .reply
    ) {
        self.route = route
        self.contextLimit = contextLimit
        self.maximumResponseTokens = maximumResponseTokens
        // Unique per test so the shared request log never mixes tests.
        let name = "\(route.rawValue)-\(UUID().uuidString)"
        self.modelID = route == .claude ? "claude-sonnet-5-5" : "apple-on-device"
        self.fake = FakeLanguageModel(name: name, reply: reply, usage: usage, delay: delay, behavior: behavior)
        self.availability = availability
    }

    public var model: any LanguageModel { fake }

    public func contextSize() async -> Int? { contextLimit }

    public var requests: [Transcript] { RequestLog.shared.transcripts(for: fake.name) }

    public var offeredTools: [String] { RequestLog.shared.toolNames(for: fake.name) }
}
