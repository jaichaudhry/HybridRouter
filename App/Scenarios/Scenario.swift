import FoundationModels
import RouterKit
import SwiftUI

/// A use case for the shared chat: configuration, not a fork of it (SPEC §5).
@MainActor
protocol Scenario {
    var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    var instructions: String { get }
    /// Shown as tappable chips above the composer.
    var samplePrompts: [String] { get }
    var mapping: ComplexityMapping { get }
    var tools: [any Tool] { get }
    /// Tools offered only on Apple routes, e.g. image tools.
    var appleOnlyTools: [any Tool] { get }
    /// Whether a sample chip fills the text field instead of sending.
    var samplePromptsFillDraft: Bool { get }
    /// Whether every attached image is private.
    var imagesArePrivate: Bool { get }
    /// Schemas for chosen kinds of turns; the first that applies is used.
    var structuredOutputs: [StructuredOutput] { get }
    /// Renders this scenario's structured replies, called with partial content as it streams.
    func card(for content: GeneratedContent) -> AnyView
}

extension Scenario {
    var mapping: ComplexityMapping { .standard }
    var tools: [any Tool] { [] }
    var appleOnlyTools: [any Tool] { [] }
    var samplePromptsFillDraft: Bool { false }
    var imagesArePrivate: Bool { false }
    var structuredOutputs: [StructuredOutput] { [] }

    func card(for content: GeneratedContent) -> AnyView {
        AnyView(Text(content.jsonString).font(.caption.monospaced()))
    }
}

/// Plain chat with no tools or cards.
struct GeneralScenario: Scenario {
    let id = "general"
    let title = "Chat"
    let symbolName = "bubble.left.and.bubble.right"
    let instructions = """
        You are a helpful assistant. Answer clearly and concisely. Use Markdown for lists and emphasis.
        """
    let samplePrompts = [
        "Give me three dinner ideas",
        "Explain how vaccines work in two paragraphs",
        "Which is better for a beginner, Swift or Kotlin, and why?",
    ]
}
