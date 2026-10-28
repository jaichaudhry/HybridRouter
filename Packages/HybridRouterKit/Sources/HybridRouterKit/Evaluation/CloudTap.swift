import Foundation
import FoundationModels
import Synchronization

/// Sits in front of a provider's model for the multi-turn benchmark. It records every request
/// the model receives, so the benchmark can check that private text never reached the cloud
/// model, and it can make the next requests fail, to measure retries and fallback against the
/// real model.
public final class CloudTap: Sendable {
    private struct State {
        var pending: [MultiTurnBenchmark.Fault.Kind] = []
        var fired = 0
        var requests: [String] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// A provider that serves `provider`'s model through this tap.
    public func wrap(_ provider: any ModelProvider) -> any ModelProvider {
        TappedProvider(wrapped: provider, tap: self)
    }

    /// Makes the next requests fail, in order: each fault fails `count` requests in a row.
    public func arm(_ faults: [MultiTurnBenchmark.Fault]) {
        state.withLock { state in
            state.pending = faults.flatMap { Array(repeating: $0.failure, count: max($0.count, 0)) }
            state.fired = 0
        }
    }

    /// Clears faults that didn't fire. Returns how many fired since ``arm(_:)``.
    @discardableResult
    public func disarm() -> Int {
        state.withLock { state in
            let fired = state.fired
            state.pending = []
            state.fired = 0
            return fired
        }
    }

    /// Every request so far, as text: instructions, history and the new prompt.
    public var requests: [String] {
        state.withLock { $0.requests }
    }

    /// The secrets that appear in any request so far.
    public func leaked(_ secrets: [String]) -> [String] {
        let requests = requests
        return secrets.filter { secret in requests.contains { $0.localizedCaseInsensitiveContains(secret) } }
    }

    fileprivate func record(_ transcript: Transcript) {
        let text = String(describing: transcript)
        state.withLock { $0.requests.append(text) }
    }

    fileprivate func nextFault() -> MultiTurnBenchmark.Fault.Kind? {
        state.withLock { state in
            guard !state.pending.isEmpty else { return nil }
            state.fired += 1
            return state.pending.removeFirst()
        }
    }

    fileprivate func model<Base: LanguageModel>(wrapping base: Base) -> any LanguageModel {
        TappedModel(base: base, tap: self)
    }
}

extension MultiTurnBenchmark.Fault.Kind {
    /// The error the real provider would throw, so retries see the same cause.
    var error: any Error {
        switch self {
        case .rateLimited: LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "Injected rate limit"))
        case .timeout: LanguageModelError.timeout(.init(debugDescription: "Injected timeout"))
        case .network: URLError(.networkConnectionLost)
        }
    }
}

private struct TappedProvider: ModelProvider {
    let wrapped: any ModelProvider
    let tap: CloudTap

    var route: Route { wrapped.route }
    var modelID: String { wrapped.modelID }
    var displayName: String { wrapped.displayName }
    var model: any LanguageModel { tap.model(wrapping: wrapped.model) }
    var availability: ProviderAvailability { wrapped.availability }
    var maximumResponseTokens: Int? { wrapped.maximumResponseTokens }
    var isSimulated: Bool { wrapped.isSimulated }
    func contextSize() async -> Int? { await wrapped.contextSize() }
}

private struct TappedModel<Base: LanguageModel>: LanguageModel {
    typealias Executor = TappedExecutor<Base>

    let base: Base
    let tap: CloudTap

    var capabilities: LanguageModelCapabilities { base.capabilities }

    var executorConfiguration: TappedExecutor<Base>.Configuration {
        .init(base: base.executorConfiguration, tap: ObjectIdentifier(tap))
    }
}

private struct TappedExecutor<Base: LanguageModel>: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        let base: Base.Executor.Configuration
        let tap: ObjectIdentifier
    }

    private let base: Base.Executor

    init(configuration: Configuration) throws {
        base = try Base.Executor(configuration: configuration.base)
    }

    func prewarm(model: TappedModel<Base>, transcript: Transcript) {
        base.prewarm(model: model.base, transcript: transcript)
    }

    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: TappedModel<Base>,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        model.tap.record(request.transcript)
        if let fault = model.tap.nextFault() {
            throw fault.error
        }
        try await base.respond(to: request, model: model.base, streamingInto: channel)
    }
}
