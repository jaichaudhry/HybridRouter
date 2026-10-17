import ClaudeForFoundationModels
import Foundation
import FoundationModels
import Testing
@testable import HybridRouterKit

struct EscalationPolicyTests {
    private let everything = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available])
    private let classified = RouteDecision(route: .onDevice, reason: "Quick conversation", source: .classifier)
    private let policy = EscalationPolicy()

    @Test func failureClimbsOneRoute() {
        #expect(policy.next(after: .timeout, decision: classified, input: everything)
            == .retry(RouteDecision(route: .appleCloud, reason: "Escalated: timed out", source: .escalation)))
    }

    @Test func unavailableRoutesAreSkipped() {
        var input = everything
        input.availability[.appleCloud] = .unavailable(reason: "off")
        #expect(policy.next(after: .contextExceeded, decision: classified, input: input)
            == .retry(RouteDecision(route: .cloud, reason: "Escalated: context too long", source: .escalation)))
    }

    @Test func routesThatDontFitAreSkipped() {
        var input = everything
        input.estimatedTokens = 50_000
        input.contextBudgets = [.onDevice: 4_000, .appleCloud: 32_000]
        let decision = RouteDecision(route: .onDevice, reason: "x", source: .rule)
        #expect(policy.next(after: .contextExceeded, decision: decision, input: input)
            == .retry(RouteDecision(route: .cloud, reason: "Escalated: context too long", source: .escalation)))
    }

    @Test func privateTurnsNeverEscalateToClaude() {
        var input = everything
        input.privacyReason = "Medical"
        let onCloud = RouteDecision(route: .appleCloud, reason: "Kept private: Medical", source: .rule)
        #expect(policy.next(after: .decodingFailed, decision: onCloud, input: input)
            == .stop(reason: "Kept private, so this wasn't sent to Claude (couldn't read the answer)."))
    }

    @Test func privateTurnsStillEscalateToAppleCloud() {
        var input = everything
        input.privacyReason = "Medical"
        let onDevice = RouteDecision(route: .onDevice, reason: "Kept private: Medical", source: .rule)
        #expect(policy.next(after: .contextExceeded, decision: onDevice, input: input)
            == .retry(RouteDecision(route: .appleCloud, reason: "Escalated: context too long", source: .escalation)))
    }

    @Test func offlineTurnsDontEscalateToTheCloud() {
        var input = everything
        input.isOnline = false
        #expect(policy.next(after: .timeout, decision: classified, input: input)
            == .stop(reason: "No larger model is available (timed out)."))
    }

    @Test func claudeHasNowhereToGo() {
        let onClaude = RouteDecision(route: .cloud, reason: "x", source: .classifier)
        #expect(policy.next(after: .emptyReply, decision: onClaude, input: everything)
            == .stop(reason: "No larger model is available (empty reply)."))
    }

    @Test func forcedRoutesAreRespected() {
        #expect(policy.next(after: .timeout, decision: .forced(.onDevice), input: everything)
            == .stop(reason: "On-device couldn't answer (timed out). Try another route."))
    }

    @Test func guardrailEscalationIsConfigurable() {
        #expect(policy.next(after: .guardrail, decision: classified, input: everything)
            == .retry(RouteDecision(route: .appleCloud, reason: "Escalated: safety filter", source: .escalation)))
        let strict = EscalationPolicy(escalatesOnGuardrail: false)
        #expect(strict.next(after: .guardrail, decision: classified, input: everything)
            == .stop(reason: "On-device couldn't answer (safety filter)."))
        #expect(strict.next(after: .refusal, decision: classified, input: everything)
            == .stop(reason: "On-device couldn't answer (model declined)."))
    }

    @Test func cancellationNeverEscalates() {
        #expect(policy.next(after: .cancelled, decision: classified, input: everything)
            == .stop(reason: "On-device couldn't answer (cancelled)."))
    }

    // MARK: Retries and fallback

    private let onCloud = RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier)

    @Test func aRateLimitIsRetriedOnceOnTheSameRouteWithBackoff() {
        let first = policy.next(after: .rateLimited, decision: onCloud, input: everything, tried: [.cloud], retries: 0, jitter: 1)
        #expect(first == .retry(RouteDecision(route: .cloud, reason: "Retried: rate limited", source: .classifier), delay: .seconds(1)))
        let doubling = EscalationPolicy(transientRetries: 3)
        #expect(doubling.next(after: .network, decision: onCloud, input: everything, retries: 2, jitter: 1)
            == .retry(RouteDecision(route: .cloud, reason: "Retried: connection lost", source: .classifier), delay: .seconds(4)))
    }

    @Test func afterItsRetryTheTopRouteFallsBack() {
        // Nothing sits above the cloud model, so a second rate limit answers on Apple Cloud.
        #expect(policy.next(after: .rateLimited, decision: onCloud, input: everything, tried: [.cloud], retries: 1)
            == .retry(RouteDecision(route: .appleCloud, reason: "Fell back: rate limited", source: .escalation)))
        var noAppleCloud = everything
        noAppleCloud.availability[.appleCloud] = .unavailable(reason: "off")
        #expect(policy.next(after: .rateLimited, decision: onCloud, input: noAppleCloud, tried: [.cloud], retries: 1)
            == .retry(RouteDecision(route: .onDevice, reason: "Fell back: rate limited", source: .escalation)))
    }

    @Test func goingOfflineMidTurnFallsBackOnDevice() {
        var offline = everything
        offline.isOnline = false
        // No retry on the same route either: it needs the network.
        #expect(policy.next(after: .network, decision: onCloud, input: offline, tried: [.cloud])
            == .retry(RouteDecision(route: .onDevice, reason: "Fell back: connection lost", source: .escalation)))
    }

    @Test func fallbackNeverRevisitsARoute() {
        let onDevice = RouteDecision(route: .onDevice, reason: "Fell back: rate limited", source: .escalation)
        var input = everything
        input.availability[.appleCloud] = .unavailable(reason: "off")
        // The cloud model already failed this turn, so on-device failing too ends it.
        #expect(policy.next(after: .timeout, decision: onDevice, input: input, tried: [.cloud, .onDevice])
            == .stop(reason: "No larger model is available (timed out)."))
    }

    @Test func appleCloudsQuotaIsNotRetriedButItsTimeoutIs() {
        let onAppleCloud = RouteDecision(route: .appleCloud, reason: "x", source: .classifier)
        #expect(policy.next(after: .rateLimited, decision: onAppleCloud, input: everything, jitter: 1)
            == .retry(RouteDecision(route: .cloud, reason: "Escalated: rate limited", source: .escalation)))
        #expect(policy.next(after: .timeout, decision: onAppleCloud, input: everything, jitter: 1)
            == .retry(RouteDecision(route: .appleCloud, reason: "Retried: timed out", source: .classifier), delay: .seconds(1)))
    }

    @Test func forcedRoutesAreRetriedButNeverMoved() {
        let forced = RouteDecision.forced(.cloud)
        #expect(policy.next(after: .rateLimited, decision: forced, input: everything, jitter: 1)
            == .retry(RouteDecision(route: .cloud, reason: "Retried: rate limited", source: .userOverride), delay: .seconds(1)))
        #expect(policy.next(after: .rateLimited, decision: forced, input: everything, retries: 1)
            == .stop(reason: "Claude couldn't answer (rate limited). Try another route."))
    }

    @Test func refusalsAndOverflowsDontFallBack() {
        #expect(policy.next(after: .refusal, decision: onCloud, input: everything)
            == .stop(reason: "No larger model is available (model declined)."))
        #expect(policy.next(after: .contextExceeded, decision: onCloud, input: everything)
            == .stop(reason: "No larger model is available (context too long)."))
    }

    @Test func fallbackCanBeTurnedOff() {
        let noFallback = EscalationPolicy(transientRetries: 0, fallsBack: false)
        #expect(noFallback.next(after: .rateLimited, decision: onCloud, input: everything)
            == .stop(reason: "No larger model is available (rate limited)."))
    }
}

struct FailureCauseTests {
    @Test func languageModelErrorsMapToCauses() {
        #expect(FailureCause(LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "")))
            == .contextExceeded)
        #expect(FailureCause(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: ""))) == .rateLimited)
        #expect(FailureCause(LanguageModelError.guardrailViolation(.init(debugDescription: ""))) == .guardrail)
        #expect(FailureCause(LanguageModelError.timeout(.init(debugDescription: ""))) == .timeout)
    }

    @Test func otherErrorsMapToCauses() {
        #expect(FailureCause(GeneratedContent.ParsingError(rawContent: "{", underlyingError: nil, debugDescription: "")) == .decodingFailed)
        #expect(FailureCause(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: ""))) == .rateLimited)
        #expect(FailureCause(CancellationError()) == .cancelled)
        #expect(FailureCause(URLError(.timedOut)) == .timeout)
        #expect(FailureCause(URLError(.cancelled)) == .cancelled)
        #expect(FailureCause(URLError(.notConnectedToInternet)) == .network)
        #expect(FailureCause(URLError(.networkConnectionLost)) == .network)
        #expect(FailureCause(ClaudeError.missingCredential) == .providerError)
    }

    @Test func onDeviceOverflowMidGenerationCountsAsContext() {
        struct GenerativeError: Error, CustomStringConvertible {
            var description: String { "Provided 4,161 tokens, but the maximum allowed is 4,096." }
        }
        #expect(FailureCause(GenerativeError()) == .contextExceeded)
    }

    @Test func everyCauseHasALabel() {
        let causes: [FailureCause] = [.contextExceeded, .guardrail, .refusal, .decodingFailed, .timeout,
                                      .rateLimited, .network, .emptyReply, .unsupported, .cancelled, .providerError]
        #expect(Set(causes.map(\.label)).count == causes.count)
    }
}
