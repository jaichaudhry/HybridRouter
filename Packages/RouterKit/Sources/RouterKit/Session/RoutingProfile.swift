import FoundationModels

extension SessionPropertyValues {
    /// The route the next request runs on. RoutedSession sets it before each turn.
    @SessionPropertyEntry var activeRoute: Route = .onDevice
}

/// One profile for the whole conversation. Its model follows `activeRoute`, so switching
/// routes keeps the shared transcript (SPEC §6, Dynamic Profiles).
struct RoutingProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let models: RouteModels

    @SessionProperty(\.activeRoute) var route

    var body: some DynamicProfile {
        Profile { Instructions(instructions) }
            .model(models[route])
            .historyTransform(HistoryPolicy.dropEarlierReasoning)
    }
}

/// The model for each route, captured from the providers once.
struct RouteModels: Sendable {
    private let onDevice: any LanguageModel
    private let appleCloud: any LanguageModel
    private let claude: any LanguageModel

    init(onDevice: any LanguageModel, appleCloud: any LanguageModel, claude: any LanguageModel) {
        self.onDevice = onDevice
        self.appleCloud = appleCloud
        self.claude = claude
    }

    subscript(route: Route) -> any LanguageModel {
        switch route {
        case .onDevice: onDevice
        case .appleCloud: appleCloud
        case .claude: claude
        }
    }
}
