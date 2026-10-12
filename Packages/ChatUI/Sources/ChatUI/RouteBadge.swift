import HybridRouterKit
import SwiftUI

/// A route's name with its icon in the route color.
public struct RouteLabel: View {
    let route: Route

    public init(_ route: Route) {
        self.route = route
    }

    public var body: some View {
        Label {
            Text(route.displayName)
        } icon: {
            Image(systemName: route.symbolName)
                .foregroundStyle(route.ink)
        }
    }
}

/// Shows where a reply ran and why. While the router is still choosing, it shows a neutral
/// "Routing…" badge whose outline sweeps through the three route colors.
public struct RouteBadge: View {
    /// Nil while the router is still choosing.
    let decision: RouteDecision?
    /// Why the turn was kept off Claude, if it was private.
    let privacyReason: String?
    /// The route is served by a stand-in model. Known from the moment the route is chosen, so
    /// the badge never shows a simulated route as the real one while a reply streams.
    let isSimulated: Bool
    /// Routes this reply tried before, in order. Shown struck through, so an escalation
    /// reads as a trail rather than a silent switch.
    let previousRoutes: [Route]
    /// Play the route icon's hop when the route is decided. Only for a reply in progress, so
    /// scrolling back through old replies doesn't replay it.
    let animatesArrival: Bool

    public init(
        decision: RouteDecision?,
        privacyReason: String? = nil,
        isSimulated: Bool = false,
        previousRoutes: [Route] = [],
        animatesArrival: Bool = false
    ) {
        self.decision = decision
        self.privacyReason = privacyReason
        self.isSimulated = isSimulated
        self.previousRoutes = previousRoutes
        self.animatesArrival = animatesArrival
    }

    public var body: some View {
        Group {
            if let decision {
                DecidedRouteBadge(
                    decision: decision,
                    privacyReason: privacyReason,
                    isSimulated: isSimulated,
                    previousRoutes: previousRoutes,
                    animatesArrival: animatesArrival
                )
                    .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
            } else {
                RoutingBadge()
                    .transition(.opacity)
            }
        }
        .animation(Motion.route, value: decision?.route)
    }
}

/// "Routing…" with an outline that slowly sweeps through the route glows.
private struct RoutingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label("Routing…", systemImage: "arrow.triangle.branch")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay {
                if reduceMotion {
                    Capsule().strokeBorder(Theme.hairline, lineWidth: 1.5)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule().strokeBorder(
                            AngularGradient(
                                colors: [Route.onDevice.glow, Route.appleCloud.glow, Route.claude.glow, Route.onDevice.glow],
                                center: .center,
                                angle: .degrees(turn * 360)
                            ),
                            lineWidth: 1.5
                        )
                    }
                }
            }
            .accessibilityLabel("Choosing a route")
    }
}

private struct DecidedRouteBadge: View {
    let decision: RouteDecision
    let privacyReason: String?
    let isSimulated: Bool
    let previousRoutes: [Route]
    let animatesArrival: Bool

    @State private var hops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(previousRoutes.enumerated()), id: \.offset) { _, route in
                Text(route.displayName)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: decision.route.symbolName)
                    .foregroundStyle(decision.route.ink)
                    .keyframeAnimator(initialValue: Hop(), trigger: hops) { icon, hop in
                        icon
                            .offset(x: hop.x, y: hop.y)
                            .scaleEffect(hop.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.x) {
                            LinearKeyframe(-12, duration: 0)
                            CubicKeyframe(0, duration: 0.45)
                        }
                        KeyframeTrack(\.y) {
                            LinearKeyframe(16, duration: 0)
                            CubicKeyframe(-7, duration: 0.22)
                            SpringKeyframe(0, duration: 0.3, spring: .snappy)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.6, duration: 0)
                            CubicKeyframe(1.15, duration: 0.25)
                            SpringKeyframe(1, duration: 0.25, spring: .snappy)
                        }
                    }
                    .onAppear(perform: hop)
                    .onChange(of: decision.route, hop)
                if let marker {
                    Image(systemName: marker)
                        .foregroundStyle(decision.route.ink)
                }
                // Wraps rather than cutting off the reason or the privacy note.
                Text("\(Text(title).fontWeight(.semibold).foregroundStyle(decision.route.ink)) \(Text(detail).foregroundStyle(.secondary))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .routeCapsule(decision.route)
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func hop() {
        if animatesArrival, !reduceMotion { hops += 1 }
    }

    struct Hop {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
    }

    private var title: String {
        decision.route.displayName + (isSimulated ? " (simulated)" : "")
    }

    private var detail: String {
        let reason = decision.reason
        // Rule decisions already say "Kept private: …"; forced and escalated ones don't.
        guard let privacyReason, !decision.reason.hasPrefix("Kept private") else { return reason }
        return "\(reason) · Kept private: \(privacyReason)"
    }

    private var accessibilityLabel: String {
        var parts = previousRoutes.map { "Tried \($0.displayName)" }
        parts.append("Answered by \(title)")
        parts.append(detail)
        return parts.joined(separator: ". ")
    }

    private var marker: String? {
        if privacyReason != nil { return "lock.fill" }
        return switch decision.source {
        case .escalation: "arrow.up.circle"
        case .userOverride: "hand.raised"
        case .rule, .classifier: nil
        }
    }
}
