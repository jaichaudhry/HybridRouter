import Testing
@testable import HybridRouterKit

struct RouteTests {
    @Test func escalationClimbsOneStepAtATime() {
        #expect(Route.onDevice.escalated == .appleCloud)
        #expect(Route.appleCloud.escalated == .cloud)
        #expect(Route.cloud.escalated == nil)
    }

    @Test func forcedDecisionNamesTheRoute() {
        let decision = RouteDecision.forced(.cloud)
        #expect(decision.source == .userOverride)
        #expect(decision.reason == "Forced: Claude")
    }
}
