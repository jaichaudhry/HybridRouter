import ClaudeForFoundationModels
import Testing
@testable import RouterKit

struct ClaudeAuthSourceTests {
    private func environment(
        clientID: String? = nil,
        isPhysicalDevice: Bool = true,
        isAppAttestSupported: Bool = true,
        developerKey: String? = nil,
        allowsDeveloperKey: Bool = true
    ) -> ClaudeAuthEnvironment {
        ClaudeAuthEnvironment(
            clientID: clientID,
            isPhysicalDevice: isPhysicalDevice,
            isAppAttestSupported: isAppAttestSupported,
            developerKey: developerKey,
            allowsDeveloperKey: allowsDeveloperKey
        )
    }

    @Test func appAttestWinsOnAPhysicalDevice() {
        let auth = ClaudeAuthSource.resolve(
            environment: environment(clientID: "clid_123", developerKey: "dev"),
            userKey: "user"
        )
        #expect(auth.mode == .appAttest(clientID: "clid_123"))
        #expect(auth.authMode == .appAttest(clientID: "clid_123"))
    }

    @Test func appAttestIsSkippedInTheSimulator() {
        let auth = ClaudeAuthSource.resolve(
            environment: environment(clientID: "clid_123", isPhysicalDevice: false),
            userKey: "user"
        )
        #expect(auth.mode == .userKey)
    }

    @Test func appAttestIsSkippedWhenUnsupported() {
        let auth = ClaudeAuthSource.resolve(
            environment: environment(clientID: "clid_123", isAppAttestSupported: false),
            userKey: nil
        )
        #expect(auth.mode == .off)
    }

    @Test func userKeyBeatsDeveloperKey() {
        let auth = ClaudeAuthSource.resolve(environment: environment(developerKey: "dev"), userKey: "user")
        #expect(auth.mode == .userKey)
        #expect(auth.authMode == .apiKey("user"))
    }

    @Test func developerKeyIsUsedWhenAllowed() {
        let auth = ClaudeAuthSource.resolve(environment: environment(developerKey: "dev"), userKey: nil)
        #expect(auth.mode == .developerKey)
        #expect(auth.authMode == .apiKey("dev"))
    }

    @Test func developerKeyIsIgnoredInReleaseBuilds() {
        let auth = ClaudeAuthSource.resolve(
            environment: environment(developerKey: "dev", allowsDeveloperKey: false),
            userKey: nil
        )
        #expect(auth.mode == .off)
        #expect(!auth.isEnabled)
    }

    @Test func blankValuesCountAsMissing() {
        let auth = ClaudeAuthSource.resolve(
            environment: environment(clientID: "  ", developerKey: "\n"),
            userKey: ""
        )
        #expect(auth.mode == .off)
    }

    @Test func keysAreTrimmed() {
        let auth = ClaudeAuthSource.resolve(environment: environment(), userKey: "  sk-test \n")
        #expect(auth.authMode == .apiKey("sk-test"))
    }

    @Test func descriptionNeverContainsTheKey() {
        let auth = ClaudeAuthSource.resolve(environment: environment(), userKey: "sk-secret")
        #expect(!auth.description.contains("sk-secret"))
        #expect(!String(describing: auth).contains("sk-secret"))
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.write("sk-test", for: KeychainStore.claudeAPIKeyAccount)
        #expect(try store.read(KeychainStore.claudeAPIKeyAccount) == "sk-test")
        try store.delete(KeychainStore.claudeAPIKeyAccount)
        #expect(try store.read(KeychainStore.claudeAPIKeyAccount) == nil)
    }
}
