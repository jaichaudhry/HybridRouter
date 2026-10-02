import Testing
@testable import RouterKit

struct RouteTests {
    @Test func escalationClimbsOneStepAtATime() {
        #expect(Route.onDevice.escalated == .appleCloud)
        #expect(Route.appleCloud.escalated == .claude)
        #expect(Route.claude.escalated == nil)
    }

    @Test func forcedDecisionNamesTheRoute() {
        let decision = RouteDecision.forced(.claude)
        #expect(decision.source == .userOverride)
        #expect(decision.reason == "Forced: Claude")
    }
}
