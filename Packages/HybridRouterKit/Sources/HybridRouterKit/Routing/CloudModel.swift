/// Which company's model serves the cloud route (`Route.claude`, the top rung). The route keeps
/// its place, rules and privacy; only the model behind it, and its name, change.
public enum CloudModel: String, CaseIterable, Codable, Sendable {
    case claude
    case museWonder

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .museWonder: "Muse Wonder"
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .museWonder: "infinity"
        }
    }

    /// The cloud model a model ID belongs to, e.g. "muse-wonder-1.0", or nil for other routes'.
    public init?(modelID: String) {
        if modelID.hasPrefix("claude") {
            self = .claude
        } else if modelID.hasPrefix("muse") {
            self = .museWonder
        } else {
            return nil
        }
    }
}

/// Names and symbols for routes, with the cloud route named for the model serving it.
public struct RouteLabels: Equatable, Sendable {
    public var cloud: CloudModel

    public init(cloud: CloudModel) {
        self.cloud = cloud
    }

    public static let standard = RouteLabels(cloud: .claude)

    /// - Parameter modelID: the model that actually answered, if known, so earlier replies keep
    ///   their own name after the cloud model is switched.
    public func name(_ route: Route, modelID: String? = nil) -> String {
        guard route == .claude else { return route.displayName }
        return cloudModel(modelID).displayName
    }

    /// These labels with the cloud route named for the model that wrote a reply, if it's a
    /// cloud model's. Use for a finished reply so it keeps its name after a switch.
    public func answered(by modelID: String?) -> RouteLabels {
        RouteLabels(cloud: cloudModel(modelID))
    }

    public func symbol(_ route: Route, modelID: String? = nil) -> String {
        guard route == .claude else { return route.symbolName }
        return cloudModel(modelID).symbolName
    }

    private func cloudModel(_ modelID: String?) -> CloudModel {
        modelID.flatMap(CloudModel.init(modelID:)) ?? cloud
    }
}
