import Foundation
import Synchronization

/// How the classifier did on one turn, for telemetry and evals.
public struct ClassifierRun: Equatable, Sendable {
    /// Nil if the classifier failed.
    public var classification: RouteClassification?
    public var latency: TimeInterval
    /// Why the classifier failed, if it did.
    public var failure: FailureCause?

    public init(classification: RouteClassification?, latency: TimeInterval, failure: FailureCause? = nil) {
        self.classification = classification
        self.latency = latency
        self.failure = failure
    }
}

/// The router's answer for one turn.
public enum RoutingResult: Equatable, Sendable {
    case routed(RouteDecision, classifier: ClassifierRun?)
    case blocked(reason: String)

    public var decision: RouteDecision? {
        if case .routed(let decision, _) = self { decision } else { nil }
    }
}

/// The classifier took longer than the router's limit.
public struct ClassifierTimeoutError: Error, Equatable {
    public init() {}
}

/// Picks a route for each turn: hard rules first, then the on-device classifier.
public struct Router: Sendable {
    public var mapping: ComplexityMapping
    /// How long the classifier may take before the turn falls back as if it had failed. About
    /// six times its usual 0.6 s on an iPhone, so it only trips when the on-device model stalls.
    /// Nil waits as long as it takes, for measuring the classifier itself: the on-device model
    /// answers one request at a time, so concurrent eval cases queue past any short limit.
    public var classifierTimeout: Duration?
    /// Sends questions with one exact answer to the cloud model before the classifier runs.
    /// See ``ExactAnswerDetector``.
    public var detectsExactAnswers: Bool
    /// What to do when the chat is too long for the route the classifier picks.
    public var whenTooLong: TooLongPolicy
    private let classifier: any RouteClassifier

    /// What happens when the conversation is too long for the route the router would pick.
    /// A route the user forces always stays put and answers from the recent turns.
    public enum TooLongPolicy: Equatable, Sendable {
        /// Move to the next route that fits the whole conversation. If none does, answer from
        /// the most recent turns that fit.
        case useLargerModel
        /// Stay on the picked route and answer from the most recent turns that fit. Cheaper and
        /// keeps more turns on the phone, but the model can't see older turns.
        case trimHistory
    }

    public init(
        classifier: any RouteClassifier,
        mapping: ComplexityMapping = .standard,
        classifierTimeout: Duration? = .seconds(4),
        detectsExactAnswers: Bool = false,
        whenTooLong: TooLongPolicy = .useLargerModel
    ) {
        self.whenTooLong = whenTooLong
        self.classifier = classifier
        self.mapping = mapping
        self.classifierTimeout = classifierTimeout
        self.detectsExactAnswers = detectsExactAnswers
    }

    /// Warms the classifier so the first turn routes as fast as later ones.
    public func prewarm() async {
        await classifier.prewarm()
    }

    /// - Parameters:
    ///   - prompt: the user's message.
    ///   - input: everything the hard rules look at for this turn.
    ///   - classifyDecidedTurns: also classify turns a rule settled, to choose a structured
    ///     output (e.g. a receipt for a scanned image). It never changes the route.
    public func route(_ prompt: String, input: RoutingInput, classifyDecidedTurns: Bool = false) async -> RoutingResult {
        var input = input
        if detectsExactAnswers, input.exactAnswer == nil {
            input.exactAnswer = ExactAnswerDetector.kind(of: prompt)
        }
        if whenTooLong == .trimHistory {
            input.staysWhenTooLong = true
        }
        let allowed: [Route]
        switch RoutingRules.evaluate(input) {
        case .decided(let decision):
            guard classifyDecidedTurns else { return .routed(decision, classifier: nil) }
            return .routed(decision, classifier: await classify(prompt, previous: input.previousPrompt))
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .open(let routes):
            allowed = routes
        }

        // The mapping can send every label to one route (e.g. only Apple Cloud and the cloud
        // model are allowed, and simple turns map up to Apple Cloud). Then classifying only adds latency.
        if !classifyDecidedTurns, let only = mapping.onlyRoute(allowed: allowed) {
            let reason = "Every request goes to \(input.labels.name(only)) here"
            return .routed(input.budgeted(RouteDecision(route: only, reason: reason, source: .rule)), classifier: nil)
        }
        let run = await classify(prompt, previous: input.previousPrompt)
        return .routed(Self.decide(run, mapping: mapping, allowed: allowed, input: input), classifier: run)
    }

    private func classify(_ prompt: String, previous: String?) async -> ClassifierRun {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let classification = if let classifierTimeout {
                try await Self.withTimeout(classifierTimeout) { [classifier] in
                    try await classifier.classify(prompt, previous: previous)
                }
            } else {
                try await classifier.classify(prompt, previous: previous)
            }
            return ClassifierRun(classification: classification, latency: start.duration(to: clock.now).seconds)
        } catch {
            return ClassifierRun(classification: nil, latency: start.duration(to: clock.now).seconds, failure: FailureCause(error))
        }
    }

    /// Runs `operation`, or throws ``ClassifierTimeoutError`` once `limit` passes. Returns at the
    /// limit even if the operation ignores cancellation, which a task group would wait for.
    static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let resumed = Mutex(false)
        func claim() -> Bool {
            resumed.withLock { done in
                defer { done = true }
                return !done
            }
        }
        let work = Mutex<Task<Void, Never>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = Task {
                    do {
                        let value = try await operation()
                        if claim() { continuation.resume(returning: value) }
                    } catch {
                        if claim() { continuation.resume(throwing: error) }
                    }
                }
                work.withLock { $0 = task }
                Task {
                    try? await Task.sleep(for: limit)
                    if claim() {
                        task.cancel()
                        continuation.resume(throwing: ClassifierTimeoutError())
                    }
                }
            }
        } onCancel: {
            work.withLock { $0?.cancel() }
        }
    }

    /// The classifier step as a pure function: map the complexity to a route and fit it to
    /// what's allowed. A failed or unusable classification falls back to Apple Cloud.
    static func decide(
        _ run: ClassifierRun,
        mapping: ComplexityMapping,
        allowed: [Route],
        input: RoutingInput
    ) -> RouteDecision {
        guard let classification = run.classification, let target = mapping.route(for: classification.complexity) else {
            let route = RoutingRules.resolve(.appleCloud, allowed: allowed) ?? allowed[0]
            let cause = run.failure.map { " (\($0.label))" } ?? ""
            return input.budgeted(RouteDecision(route: route, reason: "Couldn't classify\(cause), so using a mid-size model", source: .classifier))
        }
        // `allowed` is never empty for an open outcome.
        let route = RoutingRules.resolve(target, allowed: allowed) ?? allowed[0]
        if route == target {
            return input.budgeted(RouteDecision(route: route, reason: classification.reason, source: .classifier))
        }
        if input.isAvailable(target), !input.fits(target) {
            return input.budgeted(RouteDecision(
                route: route,
                reason: "\(classification.reason) (chat too long for \(input.labels.name(target)))",
                source: .classifier,
                tooLongFor: target
            ))
        }
        let reason = "\(classification.reason) (\(input.labels.name(target)) unavailable)"
        return input.budgeted(RouteDecision(route: route, reason: reason, source: .classifier))
    }
}
