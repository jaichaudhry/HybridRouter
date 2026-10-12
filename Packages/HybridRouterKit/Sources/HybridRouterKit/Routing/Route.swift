/// Where a conversation step runs.
public enum Route: String, CaseIterable, Codable, Sendable, Hashable {
    case onDevice
    case appleCloud
    case claude

    public var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .appleCloud: "Apple Cloud"
        case .claude: "Claude"
        }
    }

    /// SF Symbol name. Kept here so every UI shows the same icon for a route.
    public var symbolName: String {
        switch self {
        case .onDevice: "lock.iphone"
        case .appleCloud: "lock.icloud"
        case .claude: "sparkle"
        }
    }

    /// The next route up for escalation, or nil at the top.
    public var escalated: Route? {
        switch self {
        case .onDevice: .appleCloud
        case .appleCloud: .claude
        case .claude: nil
        }
    }
}
