import FoundationModels

extension SessionPropertyValues {
    /// The route the next request runs on. RoutedSession sets it before each turn.
    @SessionPropertyEntry var activeRoute: Route = .onDevice
}

/// One profile for the whole conversation. Its model follows `activeRoute`, so switching
/// routes keeps the shared transcript (SPEC §6, Dynamic Profiles).
struct RoutingProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]
    let models: RouteModels

    @SessionProperty(\.activeRoute) var route

    var body: some DynamicProfile {
        Profile {
            Instructions(instructions)
            tools
        }
            .model(models[route])
            .maximumResponseTokens(models.maximumResponseTokens(route))
            .historyTransform(HistoryPolicy.dropEarlierReasoning)
    }
}

/// The model for each route, captured from the providers once.
struct RouteModels: Sendable {
    private let onDevice: any LanguageModel
    private let appleCloud: any LanguageModel
    private let claude: any LanguageModel
    private let responseLimits: [Route: Int]

    init(onDevice: any ModelProvider, appleCloud: any ModelProvider, claude: any ModelProvider) {
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
