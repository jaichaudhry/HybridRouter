import RouterKit
import SwiftUI

/// The streaming chat: messages, optional sample-prompt chips, and the composer.
public struct ChatView: View {
    @Bindable var model: ChatModel
    let samplePrompts: [String]
    /// Chips fill the text field instead of sending, e.g. when an attachment should come first.
    let samplePromptsFillDraft: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: ChatModel, samplePrompts: [String] = [], samplePromptsFillDraft: Bool = false) {
        self.model = model
        self.samplePrompts = samplePrompts
        self.samplePromptsFillDraft = samplePromptsFillDraft
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(model.messages) { message in
                    MessageRow(message: message)
                        .id(message.id)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .animation(reduceMotion ? nil : .default, value: model.messages.count)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !samplePrompts.isEmpty {
                    SamplePromptChips(prompts: samplePrompts) { prompt in
                        if samplePromptsFillDraft {
                            model.draft = prompt
                        } else {
                            Task { await model.send(prompt) }
                        }
                    }
                    .disabled(model.isSending)
                }
                Composer(model: model)
            }
            .background(.bar)
        }
    }
}

/// Tappable sample prompts shown above the composer.
struct SamplePromptChips: View {
    let prompts: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button(prompt) { onSelect(prompt) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }
}
