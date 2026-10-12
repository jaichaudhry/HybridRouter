import FoundationModels
import Testing
@testable import HybridRouterKit

struct ProviderTests {
    @Test func onDeviceReasonsAreSpecific() {
        #expect(OnDeviceProvider.map(.available) == .available)
        #expect(OnDeviceProvider.map(.unavailable(.appleIntelligenceNotEnabled))
            == .unavailable(reason: "Apple Intelligence is turned off in Settings"))
        #expect(OnDeviceProvider.map(.unavailable(.modelNotReady))
            == .unavailable(reason: "The on-device model is still downloading"))
    }

    @Test func appleCloudIsOffUnlessTheBuildEnablesIt() {
        let provider = AppleCloudProvider(isEnabled: false)
        #expect(provider.availability == .unavailable(reason: "Apple Cloud isn't enabled in this build"))
    }

    @Test func appleCloudQuotaMakesItUnavailable() {
        #expect(AppleCloudProvider.map(.available, isLimitReached: false) == .available)
        #expect(AppleCloudProvider.map(.available, isLimitReached: true)
            == .unavailable(reason: "Daily Apple Cloud limit reached"))
        #expect(AppleCloudProvider.map(.unavailable(.systemNotReady), isLimitReached: false)
            == .unavailable(reason: "Apple Cloud isn't ready yet"))
    }

    @Test func claudeIsUnavailableWithoutAuth() {
        let provider = ClaudeProvider(auth: .off)
        #expect(provider.availability == .unavailable(reason: "Claude not configured"))
    }

    @Test func claudeTiersUseSonnetAndOpus() {
        let auth = ClaudeAuth(mode: .userKey, authMode: .apiKey("sk-test"))
        #expect(ClaudeProvider(auth: auth).modelID == "claude-sonnet-5-5")
        #expect(ClaudeProvider(auth: auth, tier: .deep).modelID == "claude-opus-5-5")
        #expect(ClaudeProvider(auth: auth).availability == .available)
    }

    @Test func simulatedAppleCloudSaysWhatItIs() async {
        let provider = SimulatedAppleCloudProvider()
        #expect(provider.route == .appleCloud)
        #expect(provider.modelID == "apple-cloud-simulated")
        #expect(provider.isSimulated)
        #expect(await provider.contextSize() == SystemLanguageModel.default.contextSize)
        #expect(try! CostTable.bundled().models["apple-cloud-simulated"]?.output == 0)
    }

    @Test func realProvidersAreNotSimulated() {
        #expect(!OnDeviceProvider().isSimulated)
        #expect(!AppleCloudProvider(isEnabled: false).isSimulated)
        #expect(!ClaudeProvider(auth: .off).isSimulated)
    }
}
