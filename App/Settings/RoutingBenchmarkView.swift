import ChatUI
import FoundationModels
import HybridRouterKit
import SwiftUI
import UIKit

/// Runs Evals/classifier_benchmark.json through the on-device classifier on this device, so
/// routing accuracy and latency are measured where users actually run the app.
struct RoutingBenchmarkView: View {
    @State private var model = BenchmarkModel()

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                LabeledContent("On-device model", value: model.modelDescription)
                Picker("Instructions", selection: $model.instructionSet) {
                    ForEach(OnDeviceClassifier.InstructionSet.all) { set in
                        Text(set.id).tag(set)
                    }
                }
                .disabled(model.isRunning)
                Button(model.isRunning ? "Running \(model.results.count)/\(model.cases.count)…" : "Run \(model.cases.count) prompts") {
                    Task { await model.run() }
                }
                .disabled(model.isRunning || model.cases.isEmpty || !SystemLanguageModel.default.isAvailable)
            } footer: {
                Text("Classifies each prompt with the on-device model, one at a time, and compares the route with the reviewed label.")
            }

            if !model.results.isEmpty {
                Section("Summary") {
                    LabeledContent("Agreement", value: "\(model.report.matches)/\(model.results.count) (\(model.report.accuracy.formatted(.percent.precision(.fractionLength(0)))))")
                    LabeledContent("Median routing time", value: model.report.medianLatency.map { "\(Int($0 * 1000)) ms" } ?? "—")
                    ForEach(model.report.accuracyByGroup, id: \.group) { group in
                        LabeledContent(group.group.capitalized, value: "\(group.matches)/\(group.total)")
                    }
                    if !model.isRunning {
                        ShareLink("Share report", item: model.reportText)
                    }
                }
                Section("Results") {
                    ForEach(model.results) { result in
                        ResultRow(result: result)
                    }
                }
            }
        }
        .navigationTitle("Routing benchmark")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResultRow: View {
    let result: RoutingBenchmark.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: result.isMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.isMatch ? .green : .red)
                    .accessibilityLabel(result.isMatch ? "Match" : "Mismatch")
                Text("#\(result.case.id) \(result.case.prompt)")
                    .font(.subheadline)
            }
            HStack(spacing: 8) {
                Text("Want \(result.expected?.displayName ?? "—")")
                Text("Got \(result.decision?.route.displayName ?? "blocked")")
                    .foregroundStyle(result.isMatch ? Color.secondary : Color.red)
                Spacer()
                Text(result.latency.map { "\(Int($0 * 1000)) ms" } ?? "rule")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let classification = result.classification {
                Text("\(classification.complexity) / \(classification.task)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
@Observable
final class BenchmarkModel {
    let cases: [RoutingBenchmark.Case]
    private(set) var results: [RoutingBenchmark.Result] = []
    private(set) var isRunning = false
    /// Which classifier instructions to benchmark; starts with the set tuned for this device.
    var instructionSet = OnDeviceClassifier.InstructionSet.tuned(for: SystemLanguageModel.default.variant)

    init() {
        let url = Bundle.main.url(forResource: "classifier_benchmark", withExtension: "json")
        cases = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? RoutingBenchmark.load($0) } ?? []
    }

    var report: RoutingBenchmark.Report { RoutingBenchmark.Report(results: results) }

    static var deviceName: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return "\(identifier), iOS \(UIDevice.current.systemVersion)"
    }

    var modelDescription: String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return "Unavailable" }
        return "\(model.variant.displayName), \(model.contextSize) tokens"
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        _ = await RoutingBenchmark.run(cases, classifier: OnDeviceClassifier(instructionSet: instructionSet)) { result in
            await self.append(result)
        }
        isRunning = false
    }

    private func append(_ result: RoutingBenchmark.Result) {
        results.append(result)
    }

    /// Plain-text report for sharing, e.g. into the README results table.
    var reportText: String {
        var lines = [
            "HybridRouter routing benchmark",
            "Device: \(Self.deviceName)",
            "On-device model: \(modelDescription)",
            "Instructions: \(instructionSet.id)",
            "Agreement: \(report.matches)/\(results.count)",
            "Median routing time: \(report.medianLatency.map { "\(Int($0 * 1000)) ms" } ?? "-")",
        ]
        lines += report.accuracyByGroup.map { "  \($0.group): \($0.matches)/\($0.total)" }
        lines += ["Misses:"] + report.misses.map { miss in
            "  #\(miss.case.id) want \(miss.expected?.rawValue ?? "-") got \(miss.decision?.route.rawValue ?? "-"): \(miss.case.prompt)"
        }
        return lines.joined(separator: "\n")
    }
}
