import Charts
import ChatUI
import HybridRouterKit
import SwiftUI
import UIKit

/// Settings › Developer › Answer quality: the answer-quality benchmark on this iPhone. Each
/// prompt is answered on every route, Claude Opus grades the answers, and the router is scored on
/// quality versus cost. Progress is saved after every prompt, so a run can stop and resume.
struct QualityEvalView: View {
    let app: AppModel
    @State private var model = QualityEvalModel()
    /// `.task(id:)` cancels a run when the screen closes, so paid requests stop too.
    @State private var runToken: UUID?

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                LabeledContent("Prompts", value: "\(model.cases.count) (\(model.cases.filter { $0.split == "heldout" }.count) held out)")
                LabeledContent("Spend cap", value: Format.dollars(QualityEvalModel.spendCap))
                if model.isRunning {
                    ProgressView(value: Double(model.progress?.done ?? 0), total: Double(max(model.progress?.total ?? 1, 1))) {
                        Text("\(model.progress?.done ?? 0) of \(model.progress?.total ?? model.cases.count) · \(Format.dollars(model.progress?.spent ?? 0)) spent")
                            .monospacedDigit()
                    } currentValueLabel: {
                        Text(model.progress?.current ?? "Starting…").lineLimit(2)
                    }
                    Button("Stop", role: .destructive) { runToken = nil }
                } else {
                    Button(model.hasSavedProgress ? "Resume" : "Run benchmark") { runToken = UUID() }
                    if model.hasSavedProgress {
                        Button("Start over", role: .destructive) { model.discardProgress() }
                    }
                }
            } footer: {
                Text("Answers every prompt on each available route plus Claude Opus, and has Opus grade each answer. Claude is billed to your key: about $9 for a full run, and it stops before passing the cap. Keep the app open; the screen stays on while it runs, and progress is saved after every prompt.")
            }

            if let run = model.result {
                if !run.unmeasured.isEmpty {
                    Section("Not measured") {
                        ForEach(run.unmeasured.sorted(by: <), id: \.key) { column, reason in
                            LabeledContent(QualityBenchmark.Column(rawValue: column)?.displayName ?? column, value: reason)
                        }
                    }
                }
                ForEach(["heldout", "tuning"], id: \.self) { split in
                    let report = QualityReport(run, split: split)
                    if report.count > 0 {
                        ReportSection(report: report, title: split == "heldout" ? "Held-out" : "Tuning")
                    }
                }
                Section {
                    if let file = model.exportFile {
                        ShareLink("Share results (JSON)", item: file)
                    }
                    ShareLink("Share summary (Markdown)", item: model.markdown)
                    if run.stoppedAtSpendCap {
                        Text("Stopped at the spend cap after \(run.cases.count) prompts.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("\(run.cases.count) prompts measured · \(Format.dollars(run.spent)) spent, judging included")
                }
            }
        }
        .navigationTitle("Answer quality")
        .task(id: runToken) {
            guard runToken != nil else { return }
            await model.run(app: app)
            runToken = nil
        }
        .onAppear { model.loadSaved() }
    }
}

/// One split's results: chart, strategy table, router breakdown and misroutes.
private struct ReportSection: View {
    let report: QualityReport
    let title: String

    var body: some View {
        Section("\(title) (\(report.count) prompts)") {
            Chart(report.strategies, id: \.strategy) { result in
                PointMark(
                    x: .value("Cost per 100 prompts ($)", result.costPer100),
                    y: .value("Answers passed (%)", result.passRate * 100)
                )
                .symbolSize(result.strategy == .router ? 160 : 70)
                .foregroundStyle(result.strategy == .router ? Theme.ink : Color.secondary)
                .annotation(position: .top, alignment: .center) {
                    Text(result.strategy.shortName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("Answers passed (%)")
            .chartXAxisLabel("Cost per 100 prompts ($)")
            .frame(height: 220)
            .padding(.vertical, 8)
            .accessibilityLabel("Answer quality versus cost for each strategy")

            ForEach(report.strategies, id: \.strategy) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.strategy.displayName)
                        .fontWeight(result.strategy == .router ? .semibold : .regular)
                    Text("\(Format.percent(result.passRate)) passed · score \(String(format: "%.2f", result.meanScore)) · \(Format.dollars(result.costPer100)) per 100 · \(Format.percent(result.claudeShare)) to Claude")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            let b = report.breakdown
            Text("Router vs the cheapest good-enough route: \(b.matched) matched, \(b.overRouted) over-routed, \(b.underRouted) under-routed, \(b.unsolved) unsolved.\(report.gapRecovered.map { " Recovers \(Format.percent($0)) of the quality gap to Claude." } ?? "")")
                .font(.footnote)

            if !report.misroutes.isEmpty {
                DisclosureGroup("Misroutes (\(report.misroutes.count))") {
                    ForEach(report.misroutes) { miss in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(miss.prompt).font(.footnote).lineLimit(3)
                            Text("\(miss.router.displayName) → should be \(miss.oracle.displayName)")
                                .font(.caption)
                                .foregroundStyle(miss.isOverRouted ? Color.secondary : Color.red)
                        }
                    }
                }
            }
        }
    }
}

private extension QualityReport.Strategy {
    var shortName: String {
        switch self {
        case .router: "Router"
        case .alwaysOnDevice: "On-device"
        case .alwaysClaude: "Sonnet"
        case .alwaysClaudeDeep: "Opus"
        case .randomSameMix: "Random"
        case .oracle: "Oracle"
        }
    }
}

private enum Format {
    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

@MainActor
@Observable
final class QualityEvalModel {
    static let spendCap = 15.0
    private static let checkpoint = URL.cachesDirectory.appending(path: "quality-benchmark-checkpoint.json")

    let cases: [QualityBenchmark.Case]
    private(set) var isRunning = false
    private(set) var progress: QualityBenchmarkRunner.Progress?
    private(set) var result: QualityBenchmark.RunResult?
    private(set) var exportFile: URL?

    init() {
        let url = Bundle.main.url(forResource: "quality_benchmark", withExtension: "json")
        cases = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? QualityBenchmark.load($0) } ?? []
    }

    var hasSavedProgress: Bool { FileManager.default.fileExists(atPath: Self.checkpoint.path()) }

    var markdown: String {
        guard let result else { return "" }
        return [
            "# Answer quality on \(result.device) (\(result.cases.count) prompts, \(Format.dollars(result.spent)))",
            QualityReport(result, split: "heldout").markdown(title: "Held-out"),
            QualityReport(result, split: "tuning").markdown(title: "Tuning"),
        ].joined(separator: "\n\n")
    }

    /// Shows results saved by an earlier, unfinished or finished run.
    func loadSaved() {
        guard result == nil, let data = try? Data(contentsOf: Self.checkpoint),
              let saved = try? QualityBenchmark.RunResult.load(data) else { return }
        show(saved)
    }

    func discardProgress() {
        try? FileManager.default.removeItem(at: Self.checkpoint)
        result = nil
        exportFile = nil
    }

    func run(app: AppModel) async {
        guard !isRunning, !cases.isEmpty else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let classifier = OnDeviceClassifier()
        let runner = QualityBenchmarkRunner(
            makeSession: { column in
                app.makeBenchmarkSession(instructions: QualityBenchmark.answerInstructions,
                                         claudeTier: column == .claudeDeep ? .deep : .standard)
            },
            judge: ModelAnswerJudge {
                app.makeBenchmarkSession(instructions: ModelAnswerJudge.instructionsForSession, claudeTier: .deep)
            },
            classifier: classifier,
            spendCap: Self.spendCap,
            checkpoint: Self.checkpoint,
            device: BenchmarkModel.deviceName,
            classifierName: "on-device classifier, \(classifier.instructionSet.id) instructions",
            judgeModelID: "claude-opus-5-5"
        )
        let result = await runner.run(cases) { [weak self] progress in
            self?.progress = progress
        }
        show(result)
    }

    private func show(_ result: QualityBenchmark.RunResult) {
        self.result = result
        let stamp = ISO8601DateFormatter.string(from: result.startedAt, timeZone: .current, formatOptions: [.withFullDate])
        let file = URL.temporaryDirectory.appending(path: "\(stamp)-iphone-quality.json")
        if let data = try? result.encoded(), (try? data.write(to: file)) != nil {
            exportFile = file
        }
    }
}
