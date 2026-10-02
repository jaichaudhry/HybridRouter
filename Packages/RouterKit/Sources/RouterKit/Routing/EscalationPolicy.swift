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
    /// The model returned nothing (e.g. a Claude refusal or truncation, which don't throw).
    case emptyReply
    case unsupported
    case cancelled
    case providerError

    /// Shown after "Escalated:" on the badge.
    public var label: String {
        switch self {
        case .contextExceeded: "context too long"
        case .guardrail: "safety filter"
        case .refusal: "model declined"
        case .decodingFailed: "couldn't read the answer"
        case .timeout: "timed out"
        case .rateLimited: "rate limited"
        case .emptyReply: "empty reply"
        case .unsupported: "unsupported request"
        case .cancelled: "cancelled"
        case .providerError: "model error"
        }
    }

    /// Maps the iOS 27 Foundation Models, Private Cloud Compute and Claude errors (API_NOTES §6).
    public init(_ error: any Error) {
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
        case is CancellationError:
            self = .cancelled
        case let error as URLError where error.code == .timedOut:
            self = .timeout
        case let error as URLError where error.code == .cancelled:
            self = .cancelled
        default:
            self = .providerError
        }
    }
}

/// What to do after a failed step.
public enum EscalationOutcome: Equatable, Sendable {
    case retry(RouteDecision)
    case stop(reason: String)
}

/// Layer C: retry a failed step one route up (SPEC §6).
public struct EscalationPolicy: Equatable, Sendable {
    /// Whether a guardrail or refusal on a smaller model should be retried on a larger one.
    public var escalatesOnGuardrail: Bool

    public init(escalatesOnGuardrail: Bool = true) {
        self.escalatesOnGuardrail = escalatesOnGuardrail
    }

    public func next(after cause: FailureCause, decision: RouteDecision, input: RoutingInput) -> EscalationOutcome {
        guard decision.source != .userOverride else {
            return .stop(reason: "\(decision.route.displayName) couldn't answer (\(cause.label)). Try another route.")
        }
        guard shouldEscalate(cause) else {
            return .stop(reason: "\(decision.route.displayName) couldn't answer (\(cause.label)).")
        }

        let higher = Route.allCases.drop { $0 != decision.route }.dropFirst()
        let candidates = higher.filter { input.isAvailable($0) && input.fits($0) && (input.isOnline || $0 == .onDevice) }
        let next = candidates.first { !(input.isPrivate && $0 == .claude) }

        guard let next else {
            if input.isPrivate, candidates.contains(.claude) {
                return .stop(reason: "Kept private, so this wasn't sent to Claude (\(cause.label)).")
            }
            return .stop(reason: "No larger model is available (\(cause.label)).")
        }
        return .retry(RouteDecision(route: next, reason: "Escalated: \(cause.label)", source: .escalation))
    }

    private func shouldEscalate(_ cause: FailureCause) -> Bool {
        switch cause {
        case .contextExceeded, .decodingFailed, .timeout, .rateLimited, .emptyReply, .providerError, .unsupported:
            true
        case .guardrail, .refusal:
            escalatesOnGuardrail
        case .cancelled:
            false
        }
    }
}
