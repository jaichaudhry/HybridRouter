import HybridRouterKit
import SwiftUI

extension Route {
    /// The route's color everywhere in the UI.
    public var tint: Color {
        switch self {
        case .onDevice: .green
        case .appleCloud: .blue
        case .claude: .orange
        }
    }
}

/// A route's name with its icon in the route color. The text stays in the primary color:
/// system green and orange text on a light background is too low-contrast to read.
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
                .foregroundStyle(route.tint)
        }
    }
}

/// Shows where a reply ran and why. Tapping it opens the metrics of every step behind it.
public struct RouteBadge: View {
    /// Nil while the router is still choosing.
    let decision: RouteDecision?
    let steps: [StepMetrics]
    /// Why the turn was kept off Claude, if it was private.
    let privacyReason: String?
    /// The route is served by a stand-in model. Known from the moment the route is chosen, so
    /// the badge never shows a simulated route as the real one while a reply streams.
    let isSimulated: Bool

    public init(decision: RouteDecision?, steps: [StepMetrics], privacyReason: String? = nil, isSimulated: Bool = false) {
        self.decision = decision
        self.steps = steps
        self.privacyReason = privacyReason
        self.isSimulated = isSimulated
    }

    public var body: some View {
        if let decision {
            DecidedRouteBadge(decision: decision, steps: steps, privacyReason: privacyReason, isSimulated: isSimulated)
        } else {
            Label("Routing…", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: .capsule)
        }
    }
}

private struct DecidedRouteBadge: View {
    let decision: RouteDecision
    let steps: [StepMetrics]
    let privacyReason: String?
    let isSimulated: Bool

    @State private var showsMetrics = false

    var body: some View {
        Button {
            showsMetrics = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Group {
                    Image(systemName: decision.route.symbolName)
                    if let marker {
                        Image(systemName: marker)
                    }
                }
                .foregroundStyle(decision.route.tint)
                // Wraps rather than cutting off the reason or the privacy note.
                Text(label)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(decision.route.tint.opacity(0.12), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(steps.isEmpty)
        .accessibilityLabel("Ran on \(decision.route.displayName). \(label)")
        .accessibilityHint(steps.isEmpty ? "" : "Shows latency, tokens and cost")
        .sheet(isPresented: $showsMetrics) {
            MetricsSheet(steps: steps)
        }
    }

    private var label: String {
        let simulated = isSimulated ? " (simulated)" : ""
        let base = switch decision.source {
        case .userOverride: decision.reason + simulated
        default: "\(decision.route.displayName)\(simulated) · \(decision.reason)"
        }
        // Rule decisions already say "Kept private: …"; forced and escalated ones don't.
        guard let privacyReason, !decision.reason.hasPrefix("Kept private") else { return base }
        return "\(base) · Kept private: \(privacyReason)"
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
