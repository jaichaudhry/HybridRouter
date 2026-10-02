import DeviceCheck
import Foundation
import RouterKit

/// Build-time configuration read from Info.plist (set through Config/*.xcconfig).
struct AppConfig {
    let isAppleCloudEnabled: Bool
    let claudeClientID: String?
    let developerKey: String?

    static func load(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfig {
        func value(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return AppConfig(
            isAppleCloudEnabled: value("HRAppleCloudEnabled") == "YES",
            claudeClientID: value("HRClaudeClientID"),
            // A scheme environment variable wins over Secrets.xcconfig.
            developerKey: environment["ANTHROPIC_API_KEY"] ?? value("HRDeveloperAnthropicKey")
        )
    }

    func claudeAuthEnvironment() -> ClaudeAuthEnvironment {
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
            clientID: claudeClientID,
            isPhysicalDevice: isPhysicalDevice,
            isAppAttestSupported: DCAppAttestService.shared.isSupported,
            developerKey: developerKey,
            allowsDeveloperKey: allowsDeveloperKey
        )
    }
}
