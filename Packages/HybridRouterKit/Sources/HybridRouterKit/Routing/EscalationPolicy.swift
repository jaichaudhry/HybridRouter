import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// Why a step failed, in terms the escalation policy and the badge understand.
public enum FailureCause: Equatable, Sendable {
    case contextExceeded
    case guardrail
    case refusal
    case decodingFailed
    case timeout
    case rateLimited
    /// The connection failed or dropped, e.g. offline or switching networks mid-reply.
    case network
    /// The model returned nothing (e.g. a Claude refusal or truncation, which don't throw).
    case emptyReply
    case unsupported
    case cancelled
    case providerError
    /// The cloud model's key was refused or is missing.
    case keyRejected
    /// The account can't pay for the reply, e.g. OpenRouter credits or a key's spending limit.
    case outOfCredits

    /// Shown after "Escalated:" on the badge.
    public var label: String {
        switch self {
        case .contextExceeded: "context too long"
        case .guardrail: "safety filter"
        case .refusal: "model declined"
        case .decodingFailed: "couldn't read the answer"
        case .timeout: "timed out"
        case .rateLimited: "rate limited"
        case .network: "connection lost"
        case .emptyReply: "empty reply"
        case .unsupported: "unsupported request"
        case .cancelled: "cancelled"
        case .providerError: "model error"
        case .keyRejected: "key not accepted"
        case .outOfCredits: "out of credits"
        }
    }

    /// Maps the iOS 27 Foundation Models, Private Cloud Compute and Claude errors.
    public init(_ error: any Error) {
        if let failure = error as? RoutedSession.StepFailure {
            self.init(failure.underlying)
            return
        }
        switch error {
        case let error as LanguageModelError:
            self = switch error {
            case .contextSizeExceeded: .contextExceeded
            case .rateLimited: .rateLimited
            case .guardrailViolation: .guardrail
            case .refusal: .refusal
            case .timeout: .timeout
            case .unsupportedCapability, .unsupportedTranscriptContent,
                 .unsupportedGenerationGuide, .unsupportedLanguageOrLocale: .unsupported
            @unknown default: .providerError
            }
        case is GeneratedContent.ParsingError:
            self = .decodingFailed
        case let error as PrivateCloudComputeLanguageModel.Error:
            self = switch error {
            case .quotaLimitReached: .rateLimited
            default: .providerError
            }
        case ClaudeError.missingCredential:
            self = .keyRejected
        case is ClassifierTimeoutError:
            self = .timeout
        case is CancellationError:
            self = .cancelled
        case let error as URLError where error.code == .timedOut:
            self = .timeout
        case let error as URLError where error.code == .cancelled:
            self = .cancelled
        case let error as URLError where Self.networkCodes.contains(error.code):
            self = .network
        default:
            self = Self.isContextOverflow(error) ? .contextExceeded
                : Self.isOutOfCredits(error) ? .outOfCredits
                : .providerError
        }
    }

    static let networkCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    /// Worth trying again on the same route after a pause: the request may succeed unchanged.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .timeout, .network: true
        default: false
        }
    }

    /// OpenRouter's 402, which the bridge passes on as an untyped API error: "This request
    /// requires more credits, or fewer max_tokens…" or "Insufficient credits". Seen October 2026.
    static func isOutOfCredits(_ error: any Error) -> Bool {
        let text = String(describing: error)
        return text.contains("requires more credits") || text.localizedCaseInsensitiveContains("insufficient credits")
    }

    /// When the on-device model runs out of context mid-generation (e.g. after tool calls), it
    /// throws a non-public `GenerativeError` ("Provided 4,161 tokens, but the maximum allowed
    /// is 4,096") instead of `LanguageModelError.contextSizeExceeded`. Observed on macOS 27.0.
    static func isContextOverflow(_ error: any Error) -> Bool {
        String(describing: error).contains("maximum allowed is")
    }
}

/// What to do after a failed step.
public enum EscalationOutcome: Equatable, Sendable {
    /// Run the turn again with this decision, after waiting `delay`: the same route for a retry,
    /// a larger one to escalate, or a smaller one to fall back.
    case retry(RouteDecision, delay: Duration = .zero)
    case stop(reason: String)
}

/// What happens after a step fails: a retry on the same route for brief failures, then
/// escalation one route up, then fallback to a smaller route. Private turns never reach the cloud model.
public struct EscalationPolicy: Equatable, Sendable {
    /// Whether a guardrail or refusal on a smaller model should be retried on a larger one.
    public var escalatesOnGuardrail: Bool
    /// Retries on the same route for a rate limit, timeout or dropped connection, before moving
    /// on. Not for on-device, which has no network, or for Apple Cloud's rate limit, a daily quota.
    public var transientRetries: Int
    /// The wait before the first retry; it doubles for each later one, with ±25% jitter.
    public var retryDelay: Duration
    /// When a larger route can't help (the top route is rate limited, or the device went
    /// offline), answer on a smaller one instead of failing. Never for a route the user forced.
    public var fallsBack: Bool

    public init(
        escalatesOnGuardrail: Bool = true,
        transientRetries: Int = 1,
        retryDelay: Duration = .seconds(1),
        fallsBack: Bool = true
    ) {
        self.escalatesOnGuardrail = escalatesOnGuardrail
        self.transientRetries = transientRetries
        self.retryDelay = retryDelay
        self.fallsBack = fallsBack
    }

    /// - Parameters:
    ///   - cause: why the step failed.
    ///   - decision: the step's route and why it was chosen.
    ///   - input: the turn's routing input, with availability and `isOnline` as they are now.
    ///   - tried: routes this turn has already run on, including `decision.route`.
    ///   - retries: how many times this turn has already retried `decision.route`.
    ///   - jitter: a factor applied to the delay, 0.75–1.25. Fixed in tests.
    public func next(
        after cause: FailureCause,
        decision: RouteDecision,
        input: RoutingInput,
        tried: Set<Route> = [],
        retries: Int = 0,
        jitter: Double = Double.random(in: 0.75...1.25)
    ) -> EscalationOutcome {
        let name = input.labels.name(decision.route)
        if cause == .cancelled {
            return .stop(reason: "\(name) couldn't answer (\(cause.label)).")
        }
        if retries < transientRetries, retriesOnSameRoute(cause, route: decision.route), usable(decision.route, input: input) {
            let delay = retryDelay * (Double(1 << retries) * jitter)
            var again = decision
            again.reason = "Retried: \(cause.label)"
            return .retry(again, delay: delay)
        }
        guard decision.source != .userOverride else {
            return .stop(reason: "\(name) couldn't answer (\(cause.label)). Try another route.")
        }

        let tried = tried.union([decision.route])
        let candidates = Route.allCases.filter { !tried.contains($0) && usable($0, input: input) }
        let order = Route.allCases.firstIndex(of: decision.route)!
        let higher = candidates.filter { Route.allCases.firstIndex(of: $0)! > order }
        let lower = candidates.filter { Route.allCases.firstIndex(of: $0)! < order }

        if shouldEscalate(cause), let next = higher.first(where: { !(input.keepsOffCloud && $0 == .cloud) }) {
            return .retry(RouteDecision(route: next, reason: "Escalated: \(cause.label)", source: .escalation))
        }
        // A smaller model can't fix a context overflow, and a refusal or guardrail is the
        // model's judgment, not a failure to route around.
        if fallsBack, fallsBackOn(cause), let next = lower.last {
            return .retry(RouteDecision(route: next, reason: "Fell back: \(cause.label)", source: .escalation))
        }
        if shouldEscalate(cause), input.keepsOffCloud, higher.contains(.cloud) {
            return .stop(reason: "Kept private, so this wasn't sent to \(input.labels.name(.cloud)) (\(cause.label)).")
        }
        return .stop(reason: shouldEscalate(cause)
            ? "No larger model is available (\(cause.label))."
            : "\(name) couldn't answer (\(cause.label)).")
    }

    private func usable(_ route: Route, input: RoutingInput) -> Bool {
        input.isAvailable(route) && input.fits(route) && (input.isOnline || route == .onDevice)
    }

    private func retriesOnSameRoute(_ cause: FailureCause, route: Route) -> Bool {
        switch route {
        case .onDevice: false
        case .appleCloud: cause.isTransient && cause != .rateLimited
        case .cloud: cause.isTransient
        }
    }

    private func fallsBackOn(_ cause: FailureCause) -> Bool {
        switch cause {
        case .rateLimited, .timeout, .network, .providerError, .keyRejected, .outOfCredits: true
        default: false
        }
    }

    private func shouldEscalate(_ cause: FailureCause) -> Bool {
        switch cause {
        case .contextExceeded, .decodingFailed, .timeout, .rateLimited, .network, .emptyReply, .providerError, .unsupported:
            true
        case .guardrail, .refusal:
            escalatesOnGuardrail
        case .cancelled, .keyRejected, .outOfCredits:
            false
        }
    }
}
