import ChatUI
import FoundationModels
import RouterKit
import SwiftUI

/// Measures each route on this device for the README results table (SPEC §12 M4): speed and
/// cost per route, and the route mix of each scenario's sample prompts on Auto.
struct MeasureRoutesView: View {
    let app: AppModel
    @State private var measurement = RouteMeasurement()

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                Button(measurement.isRunning ? measurement.status : "Measure") {
                    Task { await measurement.run(app: app) }
                }
                .disabled(measurement.isRunning)
            } footer: {
                Text("Runs \(RouteMeasurement.speedPrompts.count) prompts on each available route, then each scenario's sample prompts on Auto. Claude replies are billed to your key (a few cents).")
            }

            if !measurement.speed.isEmpty {
                Section("Speed and cost per route") {
                    ForEach(measurement.speed, id: \.route) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(row.route.displayName, systemImage: row.route.symbolName)
                                .foregroundStyle(row.route.tint)
                            if let unavailable = row.unavailableReason {
                                Text(unavailable).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("First token \(row.firstTokenText) · \(row.tokensPerSecondText) tok/s · \(row.costText) per reply")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            if !measurement.mixes.isEmpty {
                Section("Route mix on Auto") {
                    ForEach(measurement.mixes, id: \.scenario) { mix in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mix.scenario).font(.subheadline.weight(.semibold))
                            Text(mix.shareText).font(.caption)
                            Text("Cost \(ResultsFormat.money(mix.summary.totalCost)) · all-Claude \(ResultsFormat.money(mix.summary.allClaudeCost)) · saved \(ResultsFormat.money(mix.summary.saved))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !measurement.isRunning, !measurement.speed.isEmpty {
                Section {
                    ShareLink("Share as Markdown", item: measurement.markdown)
                }
            }
        }
        .navigationTitle("Measure routes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
@Observable
final class RouteMeasurement {
    struct SpeedRow {
        let route: Route
        let modelID: String
        let steps: [StepMetrics]
        let unavailableReason: String?

        var medianFirstToken: TimeInterval? { median(steps.compactMap(\.timeToFirstToken)) }
        var medianTokensPerSecond: Double? { median(steps.compactMap(\.tokensPerSecond)) }
        var averageCost: Double? {
            let costs = steps.compactMap(\.estimatedCost)
            return costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count)
        }

        var firstTokenText: String { medianFirstToken.map { "\(Int($0 * 1000)) ms" } ?? "—" }
        var tokensPerSecondText: String { medianTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—" }
        var costText: String { averageCost.map(ResultsFormat.money) ?? "—" }
    }

    struct Mix {
        let scenario: String
        let summary: SessionSummary
        let failures: Int

        var shareText: String {
            Route.allCases.map { route in
                "\(route.displayName) \(Int(((summary.routeShare[route] ?? 0) * 100).rounded()))%"
            }.joined(separator: " · ")
        }
    }

    /// Mid-length answers, so tokens per second is measured on real streaming rather than a
    /// one-line reply.
    static let speedPrompts = [
        "Explain how a refrigerator works in about 150 words.",
        "Give me a packing list for a 3-day beach trip with two kids.",
        "Rewrite this to sound friendlier: Your order is delayed. We will update you later.",
    ]

    private(set) var speed: [SpeedRow] = []
    private(set) var mixes: [Mix] = []
    private(set) var isRunning = false
    private(set) var status = ""

    func run(app: AppModel) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        speed = []
        mixes = []

        let general = app.scenarios.first { $0.id == GeneralScenario().id } ?? app.scenarios[0]
        for route in Route.allCases {
            let probe = app.makeFreshSession(for: general)
            let provider = probe.provider(for: route)
            if case .unavailable(let reason) = provider.availability {
                speed.append(SpeedRow(route: route, modelID: provider.modelID, steps: [], unavailableReason: reason))
                continue
            }
            var steps: [StepMetrics] = []
            for (index, prompt) in Self.speedPrompts.enumerated() {
                status = "\(route.displayName) \(index + 1)/\(Self.speedPrompts.count)…"
                // A fresh session per prompt, so earlier replies don't grow the input.
                let session = app.makeFreshSession(for: general)
                if let result = try? await session.respond(to: prompt, decision: .forced(route)) {
                    steps.append(result.metrics)
                }
            }
            speed.append(SpeedRow(route: route, modelID: provider.modelID, steps: steps, unavailableReason: nil))
        }

        // Document Helper's prompts need attachments, so only scenarios whose chips send directly.
        for scenario in app.scenarios where !scenario.samplePromptsFillDraft {
            let session = app.makeFreshSession(for: scenario)
            let coordinator = app.makeCoordinator(for: scenario)
            var steps: [StepMetrics] = []
            var failures = 0
            for (index, prompt) in scenario.samplePrompts.enumerated() {
                status = "\(scenario.title) \(index + 1)/\(scenario.samplePrompts.count)…"
                let outcome = await coordinator.run(
                    .init(prompt: prompt, structuredOutputs: scenario.structuredOutputs),
                    in: session
                )
                steps += outcome.steps
                if outcome.content == nil { failures += 1 }
            }
            let claudeID = session.provider(for: .claude).modelID
            mixes.append(Mix(
                scenario: scenario.title,
                summary: SessionSummary(steps: steps, costTable: app.prices, claudeModelID: claudeID),
                failures: failures
            ))
        }
        status = ""
    }

    /// The README results table.
    var markdown: String {
        var lines = [
            "Measured on \(BenchmarkModel.deviceName).",
            "",
            "| Route | Model | First token (median) | Tokens/sec (median) | Cost per reply |",
            "|---|---|---|---|---|",
        ]
        for row in speed {
            if let reason = row.unavailableReason {
                lines.append("| \(row.route.displayName) | \(row.modelID) | unavailable: \(reason) | | |")
            } else {
                lines.append("| \(row.route.displayName) | \(row.modelID) | \(row.firstTokenText) | \(row.tokensPerSecondText) | \(row.costText) |")
            }
        }
        lines += ["", "| Scenario (sample prompts on Auto) | Route mix | Cost | All on Claude | Saved |", "|---|---|---|---|---|"]
        for mix in mixes {
            lines.append("| \(mix.scenario) | \(mix.shareText) | \(ResultsFormat.money(mix.summary.totalCost)) | \(ResultsFormat.money(mix.summary.allClaudeCost)) | \(ResultsFormat.money(mix.summary.saved)) |")
        }
        return lines.joined(separator: "\n")
    }
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

enum ResultsFormat {
    static func money(_ value: Double) -> String {
        if value == 0 { return "$0" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.3f", value)
    }
}
