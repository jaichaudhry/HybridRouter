import Foundation
import HybridRouterKit

extension VoiceInput {
    /// Voice input for `assistant`, taught the names of its models so "ask Claude" or "use
    /// Apple Cloud" is heard right and routes as asked.
    public convenience init(for assistant: HybridAssistant, model: Model = .speech, vocabulary: [String] = [], locale: Locale = .current) {
        self.init(model: model, vocabulary: Self.routeNames(assistant.session.labels) + vocabulary, locale: locale)
    }

    /// The names a user might say to pick a model.
    public static func routeNames(_ labels: RouteLabels = .standard) -> [String] {
        Array(Set([labels.name(.cloud), "Claude", "Muse Wonder", "Apple Cloud", "Private Cloud Compute"])).sorted()
    }
}
