import ChatUI
import FoundationModels
import RouterKit
import SwiftUI

/// Measures each route on this device for the README results table (SPEC §12 M4): speed and
/// cost per route, and the route mix of each scenario's sample prompts on Auto.
struct MeasureRoutesView: View {
    let app: AppModel
    @State private var measurement = RouteMeasurement()
    /// `.task(id:)` cancels a run when the screen closes, so paid requests stop too.
    @State private var runToken: UUID?

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                LabeledContent("Apple Cloud", value: RouteMeasurement.appleCloudStatus(app))
                Button(measurement.isRunning ? measurement.status : "Measure") {
                    runToken = UUID()
                }
                .disabled(measurement.isRunning)
            } footer: {
                Text("Runs \(RouteMeasurement.speedPrompts.count) prompts on each available route, then each scenario's sample prompts on Auto. Claude replies are billed to your key (a few cents).")
            }

            if !measurement.speed.isEmpty {
                Section("Speed and cost per route") {
                    ForEach(measurement.speed, id: \.route) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                RouteLabel(row.route)
                                if row.isSimulated {
                                    Text("simulated on-device")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
        .task(id: runToken) {
            guard runToken != nil else { return }
            await measurement.run(app: app)
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
        /// Served by a stand-in model, so these aren't the real route's numbers.
        let isSimulated: Bool

        var routeName: String { route.displayName + (isSimulated ? " (simulated)" : "") }

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
        /// Routes served by a stand-in model during this run.
        let simulatedRoutes: Set<Route>
        /// Each sample prompt with the route its reply came from and why.
        let turns: [(prompt: String, route: String, reason: String)]

        var shareText: String {
            Route.allCases.map { route in
                "\(route.displayName)\(simulatedRoutes.contains(route) ? " (simulated)" : "") \(Int(((summary.routeShare[route] ?? 0) * 100).rounded()))%"
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

    /// Which Apple Cloud this build measures, so a report can't silently be about the wrong one.
    static func appleCloudStatus(_ app: AppModel) -> String {
        if app.isAppleCloudEnabled { return "Private Cloud Compute" }
        #if DEBUG
        return app.simulatesAppleCloud ? "Simulated on-device" : "Not enabled (Simulate Apple Cloud is off)"
        #else
        return "Not enabled (Release build)"
        #endif
    }

    private var appleCloudStatus = ""

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
        appleCloudStatus = Self.appleCloudStatus(app)

        let general = app.scenarios.first { $0.id == GeneralScenario().id } ?? app.scenarios[0]
        for route in Route.allCases {
            let probe = app.makeFreshSession(for: general)
            let provider = probe.provider(for: route)
            if case .unavailable(let reason) = provider.availability {
                speed.append(SpeedRow(route: route, modelID: provider.modelID, steps: [], unavailableReason: reason, isSimulated: provider.isSimulated))
                continue
            }
            var steps: [StepMetrics] = []
            for (index, prompt) in Self.speedPrompts.enumerated() {
                if Task.isCancelled { return }
                status = "\(route.displayName) \(index + 1)/\(Self.speedPrompts.count)…"
                // A fresh session per prompt, so earlier replies don't grow the input.
                let session = app.makeFreshSession(for: general)
                if let result = try? await session.respond(to: prompt, decision: .forced(route)) {
                    steps.append(result.metrics)
                }
            }
            speed.append(SpeedRow(route: route, modelID: provider.modelID, steps: steps, unavailableReason: nil, isSimulated: provider.isSimulated))
        }

        // Document Helper's prompts need attachments, so only scenarios whose chips send directly.
        for scenario in app.scenarios where !scenario.samplePromptsFillDraft {
            let session = app.makeFreshSession(for: scenario)
            let coordinator = app.makeCoordinator(for: scenario)
            var steps: [StepMetrics] = []
            var failures = 0
            var turns: [(prompt: String, route: String, reason: String)] = []
            for (index, prompt) in scenario.samplePrompts.enumerated() {
                if Task.isCancelled { return }
                status = "\(scenario.title) \(index + 1)/\(scenario.samplePrompts.count)…"
                let outcome = await coordinator.run(
                    .init(prompt: prompt, structuredOutputs: scenario.structuredOutputs),
                    in: session
                )
                steps += outcome.steps
                if outcome.content == nil { failures += 1 }
                turns.append((
                    prompt,
                    (outcome.decision?.route.displayName ?? "none")
                        + (outcome.steps.last?.isSimulated == true ? " (simulated)" : ""),
                    outcome.failure ?? outcome.decision?.reason ?? "-"
                ))
            }
            let claudeID = session.provider(for: .claude).modelID
            mixes.append(Mix(
                scenario: scenario.title,
                summary: SessionSummary(steps: steps, costTable: app.prices, claudeModelID: claudeID),
                failures: failures,
                simulatedRoutes: Set(Route.allCases.filter { session.provider(for: $0).isSimulated }),
                turns: turns
            ))
        }
        status = ""
    }

    /// The README results table.
    var markdown: String {
        var lines = [
            "Measured on \(BenchmarkModel.deviceName). Apple Cloud: \(appleCloudStatus).",
            "",
            "| Route | Model | First token (median) | Tokens/sec (median) | Cost per reply |",
            "|---|---|---|---|---|",
        ]
        for row in speed {
            if let reason = row.unavailableReason {
                lines.append("| \(row.routeName) | \(row.modelID) | unavailable: \(reason) | | |")
            } else {
                lines.append("| \(row.routeName) | \(row.modelID) | \(row.firstTokenText) | \(row.tokensPerSecondText) | \(row.costText) |")
            }
        }
        lines += ["", "| Scenario (sample prompts on Auto) | Route mix | Cost | All on Claude | Saved |", "|---|---|---|---|---|"]
        for mix in mixes {
            lines.append("| \(mix.scenario) | \(mix.shareText) | \(ResultsFormat.money(mix.summary.totalCost)) | \(ResultsFormat.money(mix.summary.allClaudeCost)) | \(ResultsFormat.money(mix.summary.saved)) |")
        }
        lines += ["", "Instructions: \(OnDeviceClassifier.InstructionSet.tuned(for: SystemLanguageModel.default.variant).id)"]
        for mix in mixes {
            lines += ["", "\(mix.scenario) turns:"]
            lines += mix.turns.map { "- \($0.prompt) → \($0.route) (\($0.reason))" }
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
