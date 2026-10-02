import ClaudeForFoundationModels
import Foundation
import FoundationModels
import Testing
@testable import RouterKit

struct EscalationPolicyTests {
    private let everything = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .claude: .available])
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
            == .retry(RouteDecision(route: .claude, reason: "Escalated: context too long", source: .escalation)))
    }

    @Test func routesThatDontFitAreSkipped() {
        var input = everything
        input.estimatedTokens = 50_000
        input.contextBudgets = [.onDevice: 4_000, .appleCloud: 32_000]
        let decision = RouteDecision(route: .onDevice, reason: "x", source: .rule)
        #expect(policy.next(after: .contextExceeded, decision: decision, input: input)
            == .retry(RouteDecision(route: .claude, reason: "Escalated: context too long", source: .escalation)))
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
        let onClaude = RouteDecision(route: .claude, reason: "x", source: .classifier)
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
        #expect(FailureCause(ClaudeError.missingCredential) == .providerError)
    }

    @Test func everyCauseHasALabel() {
        let causes: [FailureCause] = [.contextExceeded, .guardrail, .refusal, .decodingFailed, .timeout,
                                      .rateLimited, .emptyReply, .unsupported, .cancelled, .providerError]
        #expect(Set(causes.map(\.label)).count == causes.count)
    }
}
