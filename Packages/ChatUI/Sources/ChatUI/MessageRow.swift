import FoundationModels
import RouterKit
import SwiftUI

/// One chat bubble. Assistant replies render Markdown or structured cards and carry a route badge.
struct MessageRow: View {
    let message: ChatMessage

    @Environment(\.structuredContentRenderer) private var renderStructured

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.content.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(.tint, in: .rect(cornerRadius: 18))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                RouteBadge(decision: message.decision, steps: message.steps)
                if message.content.isEmpty {
                    if message.isStreaming {
                        ProgressView()
                            .accessibilityLabel("Thinking")
                    }
                } else {
                    reply
                }
                if let error = message.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var reply: some View {
        switch message.content {
        case .text(let text):
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .structured(let content):
            if let renderStructured {
                renderStructured.render(content)
            } else {
                Text(content.jsonString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    /// Markdown that tolerates half-streamed syntax by falling back to plain text.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
