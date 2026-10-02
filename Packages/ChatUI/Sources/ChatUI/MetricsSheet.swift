import RouterKit
import SwiftUI

/// Details for one model step: where it ran, how fast, how many tokens, what it cost.
public struct MetricsSheet: View {
    let metrics: StepMetrics
    @Environment(\.dismiss) private var dismiss

    public init(metrics: StepMetrics) {
        self.metrics = metrics
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Route") {
                    LabeledContent("Ran on") {
                        Label(metrics.route.displayName, systemImage: metrics.route.symbolName)
                            .foregroundStyle(metrics.route.tint)
                    }
                    LabeledContent("Model", value: metrics.modelID)
                    LabeledContent("Why", value: metrics.reason)
                    if let cause = metrics.escalationCause {
                        LabeledContent("Escalated", value: cause)
                    }
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
