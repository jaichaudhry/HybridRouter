/// The cloud models HybridRouterKit has providers for. The cloud route (``Route/cloud``, the top
/// rung) keeps its place, rules and privacy whichever model serves it; only the name changes.
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

    /// The cloud model a model ID belongs to, e.g. "muse-wonder-1.0", or nil for other models'.
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
    /// The cloud model's name, e.g. "Claude".
    public var cloudName: String
    /// SF Symbol name for the cloud route.
    public var cloudSymbol: String

    public init(cloudName: String, cloudSymbol: String = Route.cloud.symbolName) {
        self.cloudName = cloudName
        self.cloudSymbol = cloudSymbol
    }

    public init(cloud: CloudModel) {
        self.init(cloudName: cloud.displayName, cloudSymbol: cloud.symbolName)
    }

    /// Labels for a cloud route served by `provider`.
    public init(cloud provider: any ModelProvider) {
        if let known = CloudModel(modelID: provider.modelID) {
            self.init(cloud: known)
        } else {
            self.init(cloudName: provider.displayName)
        }
    }

    public static let standard = RouteLabels(cloud: .claude)

    /// - Parameter modelID: the model that actually answered, if known, so earlier replies keep
    ///   their own name after the cloud model is switched.
    public func name(_ route: Route, modelID: String? = nil) -> String {
        guard route == .cloud else { return route.displayName }
        return answered(by: modelID).cloudName
    }

    /// These labels with the cloud route named for the model that wrote a reply, if it's a
    /// known cloud model's. Use for a finished reply so it keeps its name after a switch.
    public func answered(by modelID: String?) -> RouteLabels {
        modelID.flatMap(CloudModel.init(modelID:)).map(RouteLabels.init(cloud:)) ?? self
    }

    public func symbol(_ route: Route, modelID: String? = nil) -> String {
        guard route == .cloud else { return route.symbolName }
        return answered(by: modelID).cloudSymbol
    }
}
