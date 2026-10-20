import HybridRouterKit
import SwiftUI

/// The streaming chat: messages, optional sample-prompt chips, and the composer.
public struct ChatView: View {
    @Bindable var model: ChatModel
    let samplePrompts: [String]
    /// Chips fill the text field instead of sending, e.g. when an attachment should come first.
    let samplePromptsFillDraft: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routeLabels) private var labels
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    /// Counts Private being switched on, to play one ripple each time.
    @State private var privateRipples = 0

    /// Keeps lines readable on iPad.
    static let readableWidth: CGFloat = 760

    public init(model: ChatModel, samplePrompts: [String] = [], samplePromptsFillDraft: Bool = false) {
        self.model = model
        self.samplePrompts = samplePrompts
        self.samplePromptsFillDraft = samplePromptsFillDraft
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if model.restoredConservatively {
                    Label("Earlier messages in this chat won't be shared with \(labels.name(.cloud)): its private messages couldn't be matched when it was reopened.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.messages) { message in
                    MessageRow(message: message, answerOnDevice: answerOnDevice(for: message))
                        .id(message.id)
                }
            }
            .padding()
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if model.messages.isEmpty {
                EmptyChatState()
                    .transition(.opacity)
            }
        }
        // While Private is on, the wash turns On-device teal: the message won't go to Claude.
        .background { ChatBackground(route: model.isPrivate ? .onDevice : lastRoute) }
        .scrollPosition($scrollPosition, anchor: .bottom)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .animation(reduceMotion ? nil : .default, value: model.messages.count)
        .onChange(of: model.messages.count) {
            // Sending while scrolled up still shows the new message and its reply.
            withAnimation(reduceMotion ? nil : .default) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: model.isPrivate) { _, isPrivate in
            if isPrivate { privateRipples += 1 }
        }
        .onChange(of: model.isSending) { wasSending, isSending in
            guard wasSending, !isSending, let reply = model.messages.last else { return }
            let announcement = reply.errorMessage
                ?? reply.decision.map { "Reply from \(labels.name($0.route, modelID: reply.metrics?.modelID))" }
                ?? "Reply finished"
            AccessibilityNotification.Announcement(announcement).post()
        }
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
                    // Centered under the lock: the composer's padding, Send and spacing put
                    // its center about 90pt from the trailing edge and 30pt from the bottom.
                    .background(alignment: .bottomTrailing) {
                        PrivateRipple(trigger: privateRipples)
                            .padding(.trailing, 78)
                            .padding(.bottom, 18)
                    }
            }
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// Offered on the reply that's waiting for its first token on a slower route.
    private func answerOnDevice(for message: ChatMessage) -> (() -> Void)? {
        guard message.id == model.messages.last?.id, model.canAnswerOnDevice else { return nil }
        return { model.answerOnDeviceInstead() }
    }

    /// The latest reply's route: the ambient wash behind the composer follows it.
    private var lastRoute: Route? {
        model.messages.last { $0.role == .assistant && $0.decision != nil }?.decision?.route
    }
}

/// The canvas, with a faint wash of the latest route's color behind the glass composer so
/// the glass picks it up. Solid canvas with Increase Contrast or Reduce Transparency.
private struct ChatBackground: View {
    let route: Route?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Theme.canvas
            .overlay(alignment: .bottom) {
                if let route, contrast != .increased, !reduceTransparency {
                    EllipticalGradient(colors: [route.glow.opacity(0.22), route.glow.opacity(0)], center: .bottom, endRadiusFraction: 0.5)
                        .frame(height: 260)
                        .id(route)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.8), value: route)
            .ignoresSafeArea()
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
                        .buttonStyle(.glass)
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

/// One soft teal ring spreading out from the lock when Private turns on. Drawn in the
/// background layer under the composer: inside the glass it was clipped away, and from
/// underneath the glass refracts it. Nothing with Reduce Motion; the haptic and the lock remain.
struct PrivateRipple: View {
    let trigger: Int

    @State private var startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let duration: TimeInterval = 1.4

    var body: some View {
        ZStack {
            if let startedAt, !reduceMotion {
                // Driven frame by frame from the start time, like the routing badge's sweep.
                TimelineView(.animation) { context in
                    RippleRing(progress: context.date.timeIntervalSince(startedAt) / Self.duration)
                }
            }
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: trigger) {
            guard trigger > 0 else { return }
            let start = Date.now
            startedAt = start
            try? await Task.sleep(for: .seconds(Self.duration))
            if startedAt == start { startedAt = nil }
        }
    }
}

/// The ripple at `progress` (0 to 1): a soft teal bloom, a wide band that thickens as it
/// spreads (like a drop in water), and a thinner second ring just behind it.
struct RippleRing: View {
    let progress: Double

    var body: some View {
        let progress = min(max(progress, 0), 1)
        ZStack {
            // Bloom: a soft filled glow that swells and fades first.
            Circle()
                .fill(RadialGradient(
                    colors: [Route.onDevice.glow.opacity(0.55), Route.onDevice.glow.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 12
                ))
                .scaleEffect(1 + 9 * eased(progress / 0.7))
                .opacity(1 - eased(progress / 0.8))
            // Main band: scaled, so its stroke widens as it travels outward.
            ring(at: progress, lineWidth: 2, reach: 14, opacity: 0.8)
            // Echo ring, starting a beat later.
            ring(at: (progress - 0.18) / 0.82, lineWidth: 1.2, reach: 9, opacity: 0.6)
        }
        .frame(width: 24, height: 24)
    }

    /// `reach` is how many times its starting size the ring grows to.
    private func ring(at progress: Double, lineWidth: CGFloat, reach: Double, opacity: Double) -> some View {
        let progress = min(max(progress, 0), 1)
        return Circle()
            .strokeBorder(Route.onDevice.glow, lineWidth: lineWidth)
            .scaleEffect(1 + (reach - 1) * eased(progress))
            .opacity(progress > 0 ? opacity * (1 - progress) : 0)
    }

    private func eased(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return 1 - pow(1 - value, 3)
    }
}
