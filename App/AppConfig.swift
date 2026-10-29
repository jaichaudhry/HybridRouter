import DeviceCheck
import Foundation
import HybridRouterKit

/// Build-time configuration read from Info.plist (set through Config/*.xcconfig).
struct AppConfig {
    let isAppleCloudEnabled: Bool
    let claudeClientID: String?
    let developerKey: String?
    /// A Meta Model API key for Muse Wonder, for Debug builds only.
    let metaDeveloperKey: String?
    /// An OpenRouter key, for Debug builds only. Shipped builds use the person's own key.
    let openRouterDeveloperKey: String?

    static func load(bundle: Bundle = .main) -> AppConfig {
        func value(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return AppConfig(
            isAppleCloudEnabled: value("HRAppleCloudEnabled") == "YES",
            claudeClientID: value("HRClaudeClientID"),
            // Only from the gitignored Secrets.xcconfig. The shared scheme is committed, so keys
            // must never go in its environment variables.
            developerKey: value("HRDeveloperAnthropicKey"),
            metaDeveloperKey: value("HRDeveloperMetaKey"),
            openRouterDeveloperKey: value("HRDeveloperOpenRouterKey")
        )
    }

    /// The Meta developer key, if this build may use one. Like the Anthropic key, never in Release.
    var allowedMetaDeveloperKey: String? {
        #if DEBUG
        metaDeveloperKey
        #else
        nil
        #endif
    }

    /// The OpenRouter developer key, if this build may use one. Never in Release.
    var allowedOpenRouterDeveloperKey: String? {
        #if DEBUG
        openRouterDeveloperKey
        #else
        nil
        #endif
    }

    /// - Parameter skipAppAttest: true after App Attest failed, so a key can be used instead.
    func claudeAuthEnvironment(skipAppAttest: Bool = false) -> ClaudeAuthEnvironment {
        #if targetEnvironment(simulator)
        let isPhysicalDevice = false
        #else
        let isPhysicalDevice = true
        #endif

        #if DEBUG
        let allowsDeveloperKey = true
        #else
        let allowsDeveloperKey = false
        #endif

        return ClaudeAuthEnvironment(
            clientID: skipAppAttest ? nil : claudeClientID,
            isPhysicalDevice: isPhysicalDevice,
            isAppAttestSupported: DCAppAttestService.shared.isSupported,
            developerKey: developerKey,
            allowsDeveloperKey: allowsDeveloperKey
        )
    }
}
