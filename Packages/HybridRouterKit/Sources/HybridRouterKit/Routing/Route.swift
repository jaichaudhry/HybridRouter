/// Where a conversation step runs.
public enum Route: String, CaseIterable, Codable, Sendable, Hashable {
    case onDevice
    case appleCloud
    /// The cloud model: Claude, Muse Wonder or another provider's. Raw value "claude" so saved
    /// results and transcripts from 0.3 and earlier still decode.
    case cloud = "claude"

    /// The route's generic name. ``RouteLabels`` names the cloud route for the model serving it.
    public var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .appleCloud: "Apple Cloud"
        case .cloud: "Cloud model"
        }
    }

    /// SF Symbol name. Kept here so every UI shows the same icon for a route.
    public var symbolName: String {
        switch self {
        case .onDevice: "lock.iphone"
        case .appleCloud: "lock.icloud"
        case .cloud: "cloud"
        }
    }

    /// The next route up for escalation, or nil at the top.
    public var escalated: Route? {
        switch self {
        case .onDevice: .appleCloud
        case .appleCloud: .cloud
        case .cloud: nil
        }
    }
}
