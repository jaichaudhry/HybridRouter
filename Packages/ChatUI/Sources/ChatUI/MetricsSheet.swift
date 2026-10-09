import RouterKit
import SwiftUI

/// Details for each model step behind a reply: where it ran, how fast, how many tokens,
/// what it cost. Escalated replies list every attempt.
public struct MetricsSheet: View {
    let steps: [StepMetrics]
    @Environment(\.dismiss) private var dismiss

    public init(steps: [StepMetrics]) {
        self.steps = steps
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, metrics in
                    StepSections(metrics: metrics, attempt: steps.count > 1 ? index + 1 : nil)
                }
            }
            .navigationTitle("Step details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct StepSections: View {
    let metrics: StepMetrics
    /// 1-based attempt number when a reply took several steps.
    let attempt: Int?

    var body: some View {
        Section {
            LabeledContent("Ran on") {
                RouteLabel(metrics.route)
            }
            LabeledContent("Model", value: metrics.modelID)
            if metrics.isSimulated {
                LabeledContent("Simulated", value: "On-device model standing in")
            }
            LabeledContent("Why", value: metrics.reason)
            if let cause = metrics.escalationCause {
                LabeledContent("Escalated after", value: cause)
            }
            if let failure = metrics.failure {
                LabeledContent("Failed", value: failure)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(attempt.map { "Attempt \($0)" } ?? "Route")
        }
        Section("Speed") {
            if let latency = metrics.classifierLatency {
                LabeledContent("Routing", value: Format.seconds(latency))
            }
            LabeledContent("First token", value: Format.seconds(metrics.timeToFirstToken))
            LabeledContent("Total", value: Format.seconds(metrics.totalLatency))
            LabeledContent("Tokens/sec", value: metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
        }
        Section("Tokens") {
            LabeledContent("Input", value: "\(metrics.usage.input)")
            LabeledContent("Cached input", value: "\(metrics.usage.cachedInput)")
            LabeledContent("Output", value: "\(metrics.usage.output)")
            LabeledContent("Reasoning", value: metrics.usage.reasoning.map(String.init) ?? "Not reported")
        }
        Section("Cost") {
            LabeledContent("Estimated", value: Format.cost(metrics.estimatedCost))
        }
    }
}

enum Format {
    static func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return value < 1 ? "\(Int((value * 1000).rounded())) ms" : String(format: "%.2f s", value)
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "Unknown" }
        if value == 0 { return "Free" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}
