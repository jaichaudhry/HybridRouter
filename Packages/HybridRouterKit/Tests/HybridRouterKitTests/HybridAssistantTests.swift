import CoreGraphics
import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

@MainActor
struct HybridAssistantTests {
    private func assistant(
        classifier: FakeClassifier = .always("simple"),
        onDevice: FakeProvider = FakeProvider(route: .onDevice, reply: "from device"),
        cloud: FakeProvider = FakeProvider(route: .cloud, reply: "from cloud"),
        privacyGuard: PrivacyGuard? = PrivacyGuard()
    ) -> HybridAssistant {
        HybridAssistant(
            instructions: "Be brief.",
            onDevice: onDevice,
            appleCloud: FakeProvider(route: .appleCloud, reply: "x", availability: .unavailable(reason: "off")),
            cloud: cloud,
            router: Router(classifier: classifier),
            policy: EscalationPolicy(retryDelay: .zero),
            estimator: FixedTokenEstimator(100),
            costTable: CostTable(updated: "", source: "", models: ["claude-sonnet-5-5": .init(input: 3, cachedInput: 0.3, output: 15)]),
            privacyGuard: privacyGuard,
            isOnline: { true }
        )
    }

    @Test func respondRoutesAndAnswers() async {
        let reply = await assistant(classifier: .always("complex", task: "reason")).respond(to: "Compare these options")
        #expect(reply.text == "from cloud")
        #expect(reply.decision == RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier))
        #expect(reply.privacyReason == nil)
        #expect(reply.cost > 0)
    }

    @Test func privacyIsCheckedByDefault() async {
        let cloud = FakeProvider(route: .cloud, reply: "leaked")
        let assistant = assistant(classifier: .always("complex"), cloud: cloud)
        let reply = await assistant.respond(to: "Email me at sam@example.com with the plan")
        #expect(reply.text == "from device")
        #expect(reply.privacyReason == "email address")
        #expect(cloud.requests.isEmpty)
        // Later turns on the cloud model only see a placeholder for it.
        _ = await assistant.respond(to: "Now compare two hotels", route: .cloud)
        let seen = cloud.requests.last.map { String(describing: $0) } ?? ""
        #expect(!seen.contains("sam@example.com"))
        #expect(seen.contains("[Private message withheld]"))
    }

    @Test func turningTheGuardOffLeavesOnlyExplicitPrivacy() async {
        let assistant = assistant(classifier: .always("complex"), privacyGuard: nil)
        #expect(assistant.privacyReason(for: "Email sam@example.com") == nil)
        #expect(assistant.privacyReason(for: "Email sam@example.com", isPrivate: true) == "marked private")
    }

    @Test func imagesStayPrivateByDefault() {
        let image = CGImage.blank
        #expect(assistant().privacyReason(for: "What's in this?", images: [ImageInput(image, label: "photo")]) == "attached image")
        let open = assistant()
        open.keepsImagesPrivate = false
        #expect(open.privacyReason(for: "What's in this?", images: [ImageInput(image, label: "photo")]) == nil)
    }

    @Test func sendStreamsTheRouteThePartialsAndTheReply() async {
        var routed: [Route] = []
        var partials = 0
        var finished: HybridAssistant.Reply?
        for await event in assistant().send("Hi there") {
            switch event {
            case .routed(let decision): routed.append(decision.route)
            case .partial: partials += 1
            case .finished(let reply): finished = reply
            }
        }
        #expect(routed == [.onDevice])
        #expect(partials > 0)
        #expect(finished?.text == "from device")
    }

    @Test func stepsAndSummaryAccumulateAcrossTurns() async {
        let assistant = assistant()
        _ = await assistant.respond(to: "Hi")
        _ = await assistant.respond(to: "Hard one", route: .cloud)
        #expect(assistant.steps.map(\.route) == [.onDevice, .cloud])
        #expect(assistant.summary.routeShare[.cloud] == 0.5)
    }

    @Test func cloudChoicesBuildTheRightProvider() {
        #expect(HybridAssistant.Cloud.off.provider.availability == .unavailable(reason: "Claude not configured"))
        #expect(HybridAssistant.Cloud.claude(apiKey: " ").provider.availability.isAvailable == false)
        #expect(HybridAssistant.Cloud.claude(apiKey: "sk-test", tier: .deep).provider.modelID == "claude-opus-5-5")
        #expect(HybridAssistant.Cloud.museWonder(apiKey: "key").provider.displayName == "Muse Wonder")
    }
}

private extension CGImage {
    static var blank: CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
