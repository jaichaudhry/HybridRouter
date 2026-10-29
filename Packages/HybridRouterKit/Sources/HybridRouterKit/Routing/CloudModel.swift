/// The cloud models HybridRouterKit has providers for. The cloud route (``Route/cloud``, the top
/// rung) keeps its place, rules and privacy whichever model serves it; only the name changes.
public enum CloudModel: String, CaseIterable, Codable, Sendable {
    case claude
    case museWonder
    /// Any model on OpenRouter, with the person's own key. Labels use the model's own name.
    case openRouter

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .museWonder: "Muse Wonder"
        case .openRouter: "OpenRouter"
        }
    }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .museWonder: "infinity"
        case .openRouter: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// The cloud model a model ID belongs to, e.g. "muse-wonder-1.0", or nil for other models'.
    /// OpenRouter's IDs name a vendor first, e.g. "openai/gpt-5.6-luna".
    public init?(modelID: String) {
        if modelID.contains("/") {
            self = .openRouter
        } else if modelID.hasPrefix("claude") {
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
    /// The model serving the cloud route, if known, so its replies keep this name.
    public var cloudModelID: String?

    public init(cloudName: String, cloudSymbol: String = Route.cloud.symbolName, cloudModelID: String? = nil) {
        self.cloudName = cloudName
        self.cloudSymbol = cloudSymbol
        self.cloudModelID = cloudModelID
    }

    public init(cloud: CloudModel) {
        self.init(cloudName: cloud.displayName, cloudSymbol: cloud.symbolName)
    }

    /// Labels for a cloud route served by `provider`.
    public init(cloud provider: any ModelProvider) {
        switch CloudModel(modelID: provider.modelID) {
        case .openRouter:
            self.init(cloudName: provider.displayName, cloudSymbol: CloudModel.openRouter.symbolName)
        case let known?:
            self.init(cloud: known)
        case nil:
            self.init(cloudName: provider.displayName)
        }
        cloudModelID = provider.modelID
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
        guard let modelID, modelID != cloudModelID, let known = CloudModel(modelID: modelID) else { return self }
        guard known == .openRouter else { return RouteLabels(cloud: known) }
        // Another OpenRouter model than the current one: its ID is all that's saved with the reply.
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return RouteLabels(cloudName: name, cloudSymbol: known.symbolName, cloudModelID: modelID)
    }

    public func symbol(_ route: Route, modelID: String? = nil) -> String {
        guard route == .cloud else { return route.symbolName }
        return answered(by: modelID).cloudSymbol
    }
}
