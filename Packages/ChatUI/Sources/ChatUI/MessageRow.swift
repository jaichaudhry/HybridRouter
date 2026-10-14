import FoundationModels
import HybridRouterKit
import SwiftUI

/// One message. User turns are neutral bubbles. Assistant replies sit on the canvas with a
/// route-colored leading edge, a route badge above and a one-line provenance row below.
struct MessageRow: View {
    let message: ChatMessage
    /// Switches a reply that's still waiting for its first token to on-device.
    var answerOnDevice: (() -> Void)?

    @Environment(\.routeLabels) private var labels

    var body: some View {
        switch message.role {
        case .user:
            UserMessage(message: message)
        case .assistant:
            AssistantMessage(message: message, answerOnDevice: answerOnDevice)
                // A finished reply keeps the name of the model that wrote it, even after the
                // cloud model is switched.
                .environment(\.routeLabels, labels.answered(by: message.metrics?.modelID))
        }
    }

    /// Markdown that tolerates half-streamed syntax by falling back to plain text.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct UserMessage: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                SentAttachments(attachments: message.attachments)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 48)
                if message.privacyReason != nil {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Route.onDevice.ink)
                }
                Text(message.content.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(Theme.userText)
                    .background(Theme.userBubble, in: .rect(cornerRadius: 20, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["You" + (message.privacyReason == nil ? "" : ", private"), message.content.text]
        if !message.attachmentNames.isEmpty {
            parts.append("Attachments: " + message.attachmentNames.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }
}

private struct AssistantMessage: View {
    let message: ChatMessage
    let answerOnDevice: (() -> Void)?

    @State private var showsMetrics = false
    @Environment(\.structuredContentRenderer) private var renderStructured
    @Environment(\.colorSchemeContrast) private var contrast

    private var route: Route? { message.decision?.route }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsMetrics = true
            } label: {
                RouteBadge(
                    decision: message.decision,
                    privacyReason: message.privacyReason,
                    isSimulated: message.routeIsSimulated,
                    previousRoutes: message.previousRoutes,
                    animatesArrival: message.isStreaming
                )
            }
            .buttonStyle(.plain)
            .disabled(message.steps.isEmpty)
            .accessibilityHint(message.steps.isEmpty ? "" : "Shows latency, tokens and cost")

            if message.content.isEmpty {
                if message.isStreaming {
                    WaitingStatus(message: message, answerOnDevice: answerOnDevice)
                        .transition(.opacity)
                }
            } else {
                reply
            }
            if let error = message.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !message.isStreaming, let metrics = message.metrics {
                Button {
                    showsMetrics = true
                } label: {
                    ProvenanceLine(metrics: metrics)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityHint("Shows latency, tokens and cost")
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(edgeStyle)
                .frame(width: 3)
                .animation(Motion.route, value: route)
        }
        .environment(\.replyRoute, route)
        .animation(Motion.fade, value: message.isStreaming)
        .sensoryFeedback(.selection, trigger: route) { _, new in new != nil && message.isStreaming }
        .sheet(isPresented: $showsMetrics) {
            MetricsSheet(steps: message.steps)
        }
    }

    /// Glow to fill, or solid ink with Increase Contrast. A neutral hairline while routing.
    private var edgeStyle: AnyShapeStyle {
        guard let route else { return AnyShapeStyle(Theme.hairline) }
        if contrast == .increased { return AnyShapeStyle(route.ink) }
        return AnyShapeStyle(LinearGradient(colors: [route.glow, route.fill], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var reply: some View {
        switch message.content {
        case .text(let text):
            // ChatModel throttles streamed updates, so parsing Markdown here stays cheap and
            // the reply doesn't flash raw "**bold**" while it streams.
            StreamingText(text: MessageRow.markdown(text), isStreaming: message.isStreaming)
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
}

/// What's happening before the first token: the router choosing, then the model thinking,
/// with the route's symbol breathing and an elapsed timer.
private struct WaitingStatus: View {
    @Environment(\.routeLabels) private var labels
    let message: ChatMessage
    let answerOnDevice: (() -> Void)?

    var body: some View {
        // Wraps the button under the status at large text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                status
                switchButton
            }
            VStack(alignment: .leading, spacing: 8) {
                status
                switchButton
            }
        }
        .animation(Motion.badge, value: answerOnDevice == nil)
    }

    @ViewBuilder private var switchButton: some View {
        if let answerOnDevice {
            Button("Answer on-device instead", systemImage: Route.onDevice.symbolName, action: answerOnDevice)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
                .transition(.opacity)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if let decision = message.decision {
                Image(systemName: labels.symbol(decision.route))
                    .foregroundStyle(decision.route.ink)
                    .symbolEffect(.breathe.pulse.byLayer, options: .repeating)
                Text("Waiting for \(labels.name(decision.route))")
                if let routedAt = message.routedAt {
                    Text("·")
                    Text(timerInterval: routedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            } else {
                Text(message.privacyReason == nil
                    ? "Checking privacy and complexity…"
                    : "Kept private: \(message.privacyReason ?? "") · choosing an Apple route…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// The finished reply's one-line summary: route · first token · cost.
private struct ProvenanceLine: View {
    let metrics: StepMetrics
    @Environment(\.routeLabels) private var labels

    var body: some View {
        Text(parts.joined(separator: " · "))
            .font(.caption)
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentShape(.rect)
    }

    private var parts: [String] {
        var parts = [labels.name(metrics.route, modelID: metrics.modelID) + (metrics.isSimulated ? " (simulated)" : "")]
        if metrics.timeToFirstToken != nil {
            parts.append("\(Format.seconds(metrics.timeToFirstToken)) first token")
        }
        if let tokensPerSecond = metrics.tokensPerSecond {
            parts.append(String(format: "%.0f tok/s", tokensPerSecond))
        }
        parts.append(Format.cost(metrics.estimatedCost))
        return parts
    }
}
