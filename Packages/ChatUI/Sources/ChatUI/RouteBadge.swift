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

/// Shows where a reply ran and why. Tapping it opens the step's metrics.
public struct RouteBadge: View {
    let decision: RouteDecision
    let metrics: StepMetrics?
    let isPrivate: Bool

    @State private var showsMetrics = false

    public init(decision: RouteDecision, metrics: StepMetrics?, isPrivate: Bool = false) {
        self.decision = decision
        self.metrics = metrics
        self.isPrivate = isPrivate
    }

    public var body: some View {
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
        .disabled(metrics == nil)
        .accessibilityLabel("Ran on \(decision.route.displayName). \(decision.reason)")
        .accessibilityHint(metrics == nil ? "" : "Shows latency, tokens and cost")
        .sheet(isPresented: $showsMetrics) {
            if let metrics {
                MetricsSheet(metrics: metrics)
            }
        }
    }

    private var label: String {
        switch decision.source {
        case .userOverride: decision.reason
        default: "\(decision.route.displayName) · \(decision.reason)"
        }
    }

    private var marker: String? {
        if isPrivate { return "lock.fill" }
        return switch decision.source {
        case .escalation: "arrow.up.circle"
        case .userOverride: "hand.raised"
        case .rule, .classifier: nil
        }
    }
}
