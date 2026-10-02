import RouterKit
import SwiftUI

/// One chat bubble. Assistant replies render Markdown and carry a route badge.
struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(.tint, in: .rect(cornerRadius: 18))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let decision = message.decision {
                    RouteBadge(decision: decision, metrics: message.metrics)
                }
                if message.text.isEmpty, message.isStreaming {
                    ProgressView()
                        .accessibilityLabel("Thinking")
                } else if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = message.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Markdown that tolerates half-streamed syntax by falling back to plain text.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
