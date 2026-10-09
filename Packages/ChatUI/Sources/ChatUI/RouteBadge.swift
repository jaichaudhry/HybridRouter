import RouterKit
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

/// Shows where a reply ran and why. Tapping it opens the metrics of every step behind it.
public struct RouteBadge: View {
    /// Nil while the router is still choosing.
    let decision: RouteDecision?
    let steps: [StepMetrics]
    /// Why the turn was kept off Claude, if it was private.
    let privacyReason: String?

    public init(decision: RouteDecision?, steps: [StepMetrics], privacyReason: String? = nil) {
        self.decision = decision
        self.steps = steps
        self.privacyReason = privacyReason
    }

    public var body: some View {
        if let decision {
            DecidedRouteBadge(decision: decision, steps: steps, privacyReason: privacyReason)
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

    @State private var showsMetrics = false

    var body: some View {
        Button {
            showsMetrics = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: decision.route.symbolName)
                if let marker {
                    Image(systemName: marker)
                }
                Text(label)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(decision.route.tint)
            .background(decision.route.tint.opacity(0.12), in: .capsule)
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
        let base = switch decision.source {
        case .userOverride: decision.reason
        default: "\(decision.route.displayName) · \(decision.reason)"
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
