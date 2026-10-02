import FoundationModels
import SwiftUI

/// Renders structured replies, e.g. itinerary cards. Compared by `id` so SwiftUI only
/// invalidates views when the renderer actually changes.
struct StructuredContentRenderer: Equatable {
    let id: String
    let render: @MainActor (GeneratedContent) -> AnyView

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var structuredContentRenderer: StructuredContentRenderer? = nil
}

extension View {
    /// How the chat renders structured replies. Called repeatedly with partial content as it streams.
    /// - Parameter id: identifies the renderer, e.g. the scenario's ID.
    public func structuredContent<Content: View>(
        id: String,
        @ViewBuilder _ render: @escaping @MainActor (GeneratedContent) -> Content
    ) -> some View {
        environment(\.structuredContentRenderer, StructuredContentRenderer(id: id) { AnyView(render($0)) })
    }
}
