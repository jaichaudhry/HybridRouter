import ClaudeForFoundationModels
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// How the app authenticates to Claude, shown in Settings.
public enum ClaudeAuthMode: Equatable, Sendable {
    case appAttest(clientID: String)
    case userKey
    case developerKey
    case off

    public var displayName: String {
        switch self {
        case .appAttest: "App Attest"
        case .userKey: "Your key"
        case .developerKey: "Dev key"
        case .off: "Off"
        }
    }
}

/// Everything auth resolution depends on, gathered once at launch.
public struct ClaudeAuthEnvironment: Sendable {
    /// Anthropic Console client ID (`clid_…`) for App Attest, if configured.
    public var clientID: String?
    public var isPhysicalDevice: Bool
    public var isAppAttestSupported: Bool
    /// Key from the scheme environment or Secrets.xcconfig.
    public var developerKey: String?
    /// False in release builds, so a developer key can never ship.
    public var allowsDeveloperKey: Bool

    public init(
        clientID: String?,
        isPhysicalDevice: Bool,
        isAppAttestSupported: Bool,
        developerKey: String?,
        allowsDeveloperKey: Bool
    ) {
        self.clientID = clientID
        self.isPhysicalDevice = isPhysicalDevice
        self.isAppAttestSupported = isAppAttestSupported
        self.developerKey = developerKey
        self.allowsDeveloperKey = allowsDeveloperKey
    }

    /// This device and build: whether it's a simulator, whether App Attest is supported, and
    /// whether developer keys are allowed (Debug builds only).
    public static func current(clientID: String? = nil, developerKey: String? = nil) -> ClaudeAuthEnvironment {
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
        #if canImport(DeviceCheck)
        let isAppAttestSupported = DCAppAttestService.shared.isSupported
        #else
        let isAppAttestSupported = false
        #endif
        return ClaudeAuthEnvironment(
            clientID: clientID,
            isPhysicalDevice: isPhysicalDevice,
            isAppAttestSupported: isAppAttestSupported,
            developerKey: developerKey,
            allowsDeveloperKey: allowsDeveloperKey
        )
    }
}

/// The resolved Claude credentials. `authMode` is nil when Claude is off.
public struct ClaudeAuth: Sendable, CustomStringConvertible {
    public let mode: ClaudeAuthMode
    public let authMode: AuthMode?

    public static let off = ClaudeAuth(mode: .off, authMode: nil)

    /// An Anthropic API key. Fine for development and personal apps; a shipped app should use
    /// ``appAttest(clientID:)`` so no key is embedded. A blank key turns Claude off.
    public static func apiKey(_ key: String) -> ClaudeAuth {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? .off : ClaudeAuth(mode: .userKey, authMode: .apiKey(key))
    }

    /// App Attest with your Claude Console client ID (`clid_…`). Needs a physical device that
    /// supports App Attest.
    public static func appAttest(clientID: String) -> ClaudeAuth {
        ClaudeAuth(mode: .appAttest(clientID: clientID), authMode: .appAttest(clientID: clientID))
    }

    public var isEnabled: Bool { authMode != nil }

    /// Never includes the key.
    public var description: String { "ClaudeAuth(\(mode.displayName))" }
}

/// Picks Claude credentials in priority order:
/// App Attest on a real device, then the user's Keychain key, then a developer key, then off.
public enum ClaudeAuthSource {
    public static func resolve(environment: ClaudeAuthEnvironment, userKey: String?) -> ClaudeAuth {
        if let clientID = environment.clientID.nonBlank,
           environment.isPhysicalDevice,
           environment.isAppAttestSupported {
            return ClaudeAuth(mode: .appAttest(clientID: clientID), authMode: .appAttest(clientID: clientID))
        }
        if let key = userKey.nonBlank {
            return ClaudeAuth(mode: .userKey, authMode: .apiKey(key))
        }
        if environment.allowsDeveloperKey, let key = environment.developerKey.nonBlank {
            return ClaudeAuth(mode: .developerKey, authMode: .apiKey(key))
        }
        return .off
    }
}

private extension Optional where Wrapped == String {
    /// The trimmed value, or nil if missing or blank.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
