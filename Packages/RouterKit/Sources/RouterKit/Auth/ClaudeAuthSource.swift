import ClaudeForFoundationModels
import Foundation

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
}

/// The resolved Claude credentials. `authMode` is nil when Claude is off.
public struct ClaudeAuth: Sendable, CustomStringConvertible {
    public let mode: ClaudeAuthMode
    public let authMode: AuthMode?

    public static let off = ClaudeAuth(mode: .off, authMode: nil)

    public var isEnabled: Bool { authMode != nil }

    /// Never includes the key.
    public var description: String { "ClaudeAuth(\(mode.displayName))" }
}

/// Picks Claude credentials in priority order (SPEC §7):
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
