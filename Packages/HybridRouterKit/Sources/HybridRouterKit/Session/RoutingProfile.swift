import FoundationModels

extension SessionPropertyValues {
    /// The route the next request runs on. RoutedSession sets it before each turn.
    @SessionPropertyEntry var activeRoute: Route = .onDevice
}

/// One profile for the whole conversation. Its model follows `activeRoute`, so switching
/// routes keeps the shared transcript (Foundation Models Dynamic Profiles).
struct RoutingProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    /// Tools for Apple routes only, e.g. OCRTool, which finds images by attachment label;
    /// the Claude bridge doesn't forward labels.
    let appleOnlyTools: [any Tool]
    let models: RouteModels
    let privacy: PrivacyLedger

    @SessionProperty(\.activeRoute) var route

    var body: some DynamicProfile {
        let activeTools = route == .claude ? tools : tools + appleOnlyTools
        Profile {
            Instructions(instructions + "\n\n" + Self.routeNote(for: route, cloud: models.cloud))
            activeTools
        }
            .model(models[route])
            .maximumResponseTokens(models.maximumResponseTokens(route))
            .historyTransform { [privacy] entries in
                // Read the route from the ledger, set just before each request, rather than
                // relying on when the framework re-evaluates this body.
                HistoryPolicy.prepare(entries, for: privacy.route, privatePromptIDs: privacy.privatePromptIDs)
            }
    }
}

extension RoutingProfile {
    /// Tells each model it's one of several in this conversation. Without it, the on-device
    /// model answered "but Claude can?" with "I am a foundation model developed by Apple — I
    /// cannot be Claude." Muse Wonder took the note as something to say, signing replies "I'm Muse
    /// Wonder", so it's only for when the user asks. It only changes with the route, so Claude's
    /// prompt cache holds.
    static func routeNote(for route: Route, cloud: CloudModel = .claude) -> String {
        """
        This conversation is shared by three models: Apple's on-device model, Apple Private Cloud Compute and \(cloud.displayName). \
        Earlier replies may have come from a different one. This reply is from \(route.modelDescription(cloud: cloud)). \
        Don't mention this unless the user asks which model is answering or wants a different one; \
        then tell them they can ask for a model by name.
        """
    }
}

private extension Route {
    func modelDescription(cloud: CloudModel) -> String {
        switch self {
        case .onDevice: "Apple's on-device model"
        case .appleCloud: "Apple Private Cloud Compute"
        case .claude: cloud.displayName
        }
    }
}

/// The model for each route, captured from the providers once.
struct RouteModels: Sendable {
    private let onDevice: any LanguageModel
    private let appleCloud: any LanguageModel
    private let claude: any LanguageModel
    private let responseLimits: [Route: Int]
    /// Which model serves the cloud route.
    let cloud: CloudModel

    init(onDevice: any ModelProvider, appleCloud: any ModelProvider, claude: any ModelProvider) {
        self.cloud = CloudModel(modelID: claude.modelID) ?? .claude
        self.onDevice = onDevice.model
        self.appleCloud = appleCloud.model
        self.claude = claude.model
        self.responseLimits = [onDevice, appleCloud, claude].reduce(into: [:]) { limits, provider in
            limits[provider.route] = provider.maximumResponseTokens
        }
    }

    func maximumResponseTokens(_ route: Route) -> Int? {
        responseLimits[route]
    }

    subscript(route: Route) -> any LanguageModel {
        switch route {
        case .onDevice: onDevice
        case .appleCloud: appleCloud
        case .claude: claude
        }
    }
}
