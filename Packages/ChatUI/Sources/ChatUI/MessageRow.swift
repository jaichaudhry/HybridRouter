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
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    Spacer(minLength: 48)
                    if message.privacyReason != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.content.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Self.userBubble, in: .rect(cornerRadius: 18))
                }
                if !message.attachmentNames.isEmpty {
                    Label(message.attachmentNames.joined(separator: ", "), systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(userAccessibilityLabel)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                RouteBadge(decision: message.decision, steps: message.steps, privacyReason: message.privacyReason)
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
            // Parsing Markdown on every streamed snapshot is wasted main-thread work; render
            // plain text while streaming and Markdown once the reply is complete.
            Text(message.isStreaming ? AttributedString(text) : Self.markdown(text))
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

    /// #0060DF: white text on it passes 4.5:1, which the default tint doesn't.
    static let userBubble = Color(red: 0, green: 0.376, blue: 0.875)

    private var userAccessibilityLabel: String {
        var parts = ["You" + (message.privacyReason == nil ? "" : ", private"), message.content.text]
        if !message.attachmentNames.isEmpty {
            parts.append("Attachments: " + message.attachmentNames.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }

    /// Markdown that tolerates half-streamed syntax by falling back to plain text.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
