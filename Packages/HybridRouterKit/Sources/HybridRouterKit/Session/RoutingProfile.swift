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
    /// the cloud model's bridge doesn't forward labels.
    let appleOnlyTools: [any Tool]
    let models: RouteModels
    let privacy: PrivacyLedger
    let history: HistoryPolicy

    @SessionProperty(\.activeRoute) var route

    var body: some DynamicProfile {
        let activeTools = route == .cloud ? tools : tools + appleOnlyTools
        Profile {
            Instructions(instructions + "\n\n" + Self.routeNote(for: route, models: models.names))
            activeTools
        }
            .model(models[route])
            .maximumResponseTokens(models.maximumResponseTokens(route))
            .historyTransform { [privacy, history] entries in
                // Read the route from the ledger, set just before each request, rather than
                // relying on when the framework re-evaluates this body.
                history.prepare(
                    entries,
                    for: privacy.route,
                    privatePromptIDs: privacy.privatePromptIDs,
                    turnLimit: privacy.turnLimit
                ) { kept, total in
                    privacy.seen = .init(seen: kept, total: total)
                }
            }
    }
}

extension RoutingProfile {
    /// Tells each model it's one of several in this conversation. Without it, the on-device
    /// model answered "but Claude can?" with "I am a foundation model developed by Apple — I
    /// cannot be Claude." Muse Wonder took the note as something to say, signing replies "I'm Muse
    /// Wonder", so it's only for when the user asks. On an iPhone, the on-device model still named
    /// itself in 3 of its 70 replies in chats Claude had answered before ("— Apple's on-device
    /// assistant"), and in none of 137 in chats it answered alone, hence "or sign your reply".
    /// It only changes with the route, so the cloud model's prompt cache holds.
    /// - Parameter models: each available route's model name, cheapest first.
    static func routeNote(for route: Route, models: [Route: String]) -> String {
        let names = Route.allCases.compactMap { models[$0] }
        let current = models[route] ?? route.displayName
        guard names.count > 1 else { return "This reply is from \(current)." }
        let list = names.dropLast().joined(separator: ", ") + " and " + names.last!
        return """
            This conversation is shared by \(names.count) models: \(list). \
            Earlier replies may have come from a different one. This reply is from \(current). \
            Don't mention this or sign your reply with a model name unless the user asks which model is answering or wants a different one; \
            then tell them they can ask for a model by name.
            """
    }
}

/// The model for each route, captured from the providers once.
struct RouteModels: Sendable {
    private let onDevice: any LanguageModel
    private let appleCloud: any LanguageModel
    private let cloud: any LanguageModel
    private let responseLimits: [Route: Int]
    /// How the route note names each route's model, for the routes available at the start.
    let names: [Route: String]

    init(onDevice: any ModelProvider, appleCloud: any ModelProvider, cloud: any ModelProvider) {
        self.onDevice = onDevice.model
        self.appleCloud = appleCloud.model
        self.cloud = cloud.model
        let providers = [onDevice, appleCloud, cloud]
        self.responseLimits = providers.reduce(into: [:]) { limits, provider in
            limits[provider.route] = provider.maximumResponseTokens
        }
        self.names = providers.reduce(into: [:]) { names, provider in
            guard provider.availability.isAvailable else { return }
            names[provider.route] = switch provider.route {
            case .onDevice: "Apple's on-device model"
            case .appleCloud: "Apple Private Cloud Compute"
            case .cloud: provider.displayName
            }
        }
    }

    func maximumResponseTokens(_ route: Route) -> Int? {
        responseLimits[route]
    }

    subscript(route: Route) -> any LanguageModel {
        switch route {
        case .onDevice: onDevice
        case .appleCloud: appleCloud
        case .cloud: cloud
        }
    }
}
