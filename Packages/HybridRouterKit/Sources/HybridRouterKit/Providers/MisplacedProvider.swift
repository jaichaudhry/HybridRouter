import FoundationModels

/// A provider passed for a route it doesn't serve, e.g. a ClaudeProvider as `onDevice:`. It keeps
/// the route unavailable, with a reason, rather than crashing or sending turns to the wrong model.
struct MisplacedProvider: ModelProvider {
    let wrapped: any ModelProvider
    let route: Route

    init(wrapped: any ModelProvider, slot: Route) {
        self.wrapped = wrapped
        self.route = slot
    }

    var modelID: String { wrapped.modelID }
    var displayName: String { wrapped.displayName }
    var model: any LanguageModel { wrapped.model }
    var price: CostTable.Price? { wrapped.price }

    var availability: ProviderAvailability {
        .unavailable(reason: "Misconfigured: a \(wrapped.route.displayName) provider was passed for \(route.displayName)")
    }

    func contextSize() async -> Int? { await wrapped.contextSize() }
}
