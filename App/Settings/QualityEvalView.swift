import Charts
import ChatUI
import FoundationModels
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
    @State private var runMode = QualityEvalModel.Mode.full
    @State private var replayInstructions = OnDeviceClassifier.InstructionSet.tuned(for: SystemLanguageModel.default.variant).id

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
                    Button(model.hasSavedProgress ? "Resume" : "Run benchmark") { start(.full) }
                    if model.hasSavedProgress {
                        Button("Start over", role: .destructive) { model.discardProgress() }
                    }
                }
            } footer: {
                Text("Answers every prompt on each available route plus Claude Opus (and Muse Wonder, with a Meta key), and has Opus grade each answer. Calls are billed to your keys: about $9 for a full run, about $16 with Muse Wonder, and it stops before passing the cap. Keep the app open; the screen stays on while it runs, and progress is saved after every prompt.")
            }

            if !model.testCases.isEmpty {
                Section {
                    if !model.isRunning {
                        Button(model.hasSavedTestProgress ? "Resume the test set" : "Run the test set") { start(.testSet) }
                        if model.hasSavedTestProgress {
                            Button("Start over", role: .destructive) { model.discardTestProgress() }
                        }
                    }
                } header: {
                    Text("Test set (\(model.testCases.count) prompts)")
                } footer: {
                    Text("Fresh prompts kept aside to confirm routing changes; never used for tuning. Answered on-device and by Claude Sonnet only, and graded by Opus: about $5 and 30 minutes. Run it once, then compare routings on it with Replay.")
                }
            }

            if model.baseline != nil {
                Section {
                    Picker("Classifier instructions", selection: $replayInstructions) {
                        ForEach(OnDeviceClassifier.InstructionSet.all) { set in
                            Text(set.id).tag(set.id)
                        }
                    }
                    if !model.isRunning {
                        Button("Replay routing on the 0.2.0 results") { start(.replay) }
                    }
                    ForEach(model.comparisons, id: \.split) { item in
                        LabeledContent(item.split == "heldout" ? "Held-out vs 0.2.0" : "Tuning vs 0.2.0") {
                            Text(item.comparison.summary)
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Replay routing")
                } footer: {
                    Text("Runs only the router over the saved answers, so a routing change is measured for free, in about two minutes. Intervals are 95% bootstrap ranges.")
                }
            }

            // Only with the real entitlement: a stand-in says nothing about Apple Cloud.
            if app.isAppleCloudEnabled, model.baseline != nil {
                Section {
                    if !model.isRunning {
                        Button(model.hasSavedAppleCloudProgress ? "Resume adding Apple Cloud" : "Add Apple Cloud to the 0.2.0 results") {
                            start(.addAppleCloud)
                        }
                        if model.hasSavedAppleCloudProgress {
                            Button("Start over", role: .destructive) { model.discardAppleCloudProgress() }
                        }
                    }
                } header: {
                    Text("Help measure Apple Cloud")
                } footer: {
                    Text("Answers the same prompts on Private Cloud Compute and adds them to HybridRouter's published results, without re-answering the other models: about 15 minutes. Claude Opus grades each answer, about $3 on your Claude key; Apple Cloud itself is free. If Apple Cloud reaches its daily limit, the run stops and resumes later. Then share the results on the GitHub issue.")
                }
            }

            if let run = model.result {
                if run.stoppedAtRateLimit == true {
                    Section {
                        Label("Apple Cloud reached its daily limit. Progress is saved; resume later.", systemImage: "hourglass")
                    }
                }
                if let note = run.routerNote {
                    Section {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
            switch runMode {
            case .full: await model.run(app: app)
            case .testSet: await model.run(app: app, testSet: true)
            case .addAppleCloud: await model.addAppleCloud(app: app)
            case .replay:
                let set = OnDeviceClassifier.InstructionSet.all.first { $0.id == replayInstructions }
                await model.replay(instructions: set)
            }
            runToken = nil
        }
        .onAppear { model.loadSaved() }
    }

    private func start(_ mode: QualityEvalModel.Mode) {
        runMode = mode
        runToken = UUID()
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
        case .alwaysAppleCloud: "Apple Cloud"
        case .alwaysClaude: "Sonnet"
        case .alwaysClaudeDeep: "Opus"
        case .alwaysMuseWonder: "Muse"
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
    enum Mode { case full, testSet, addAppleCloud, replay }

    static let spendCap = 15.0
    private static let checkpoint = URL.cachesDirectory.appending(path: "quality-benchmark-checkpoint.json")
    private static let appleCloudCheckpoint = URL.cachesDirectory.appending(path: "quality-applecloud-checkpoint.json")
    private static let testCheckpoint = URL.cachesDirectory.appending(path: "quality-testset-checkpoint.json")
    /// HybridRouter's published 0.2.0 results, bundled so people with the Private Cloud Compute
    /// entitlement can add Apple Cloud to them.
    private static let baselineName = "2026-10-14-iphone-quality-muse"

    let cases: [QualityBenchmark.Case]
    private(set) var isRunning = false
    private(set) var progress: QualityBenchmarkRunner.Progress?
    private(set) var result: QualityBenchmark.RunResult?
    private(set) var exportFile: URL?
    /// The last replay compared with the 0.2.0 routing, per split.
    private(set) var comparisons: [(split: String, comparison: QualityReplay.Comparison)] = []

    /// The frozen test set for routing changes: answered on-device and by Sonnet only.
    let testCases: [QualityBenchmark.Case]

    init() {
        func load(_ name: String) -> [QualityBenchmark.Case] {
            Bundle.main.url(forResource: name, withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? QualityBenchmark.load($0) } ?? []
        }
        cases = load("quality_benchmark")
        testCases = load("quality_testset")
    }

    var hasSavedProgress: Bool { FileManager.default.fileExists(atPath: Self.checkpoint.path()) }
    var hasSavedAppleCloudProgress: Bool { FileManager.default.fileExists(atPath: Self.appleCloudCheckpoint.path()) }
    var hasSavedTestProgress: Bool { FileManager.default.fileExists(atPath: Self.testCheckpoint.path()) }

    /// The bundled 0.2.0 results, or nil if missing from the bundle.
    var baseline: QualityBenchmark.RunResult? {
        Bundle.main.url(forResource: Self.baselineName, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? QualityBenchmark.RunResult.load($0) }
    }

    var markdown: String {
        guard let result else { return "" }
        return [
            "# Answer quality on \(result.device) (\(result.cases.count) prompts, \(Format.dollars(result.spent)))"
                + (result.routerNote.map { "\n\n\($0) Classifier: \(result.classifier)." } ?? "")
                + comparisons.map { "\n\n\($0.split == "heldout" ? "Held-out" : "Tuning") vs 0.2.0 routing: \($0.comparison.summary)" }.joined(),
            QualityReport(result, split: "heldout").markdown(title: "Held-out"),
            QualityReport(result, split: "tuning").markdown(title: "Tuning"),
        ].joined(separator: "\n\n")
    }

    /// Shows results saved by an earlier, unfinished or finished run.
    func loadSaved() {
        guard result == nil else { return }
        if let data = try? Data(contentsOf: Self.appleCloudCheckpoint), let saved = try? QualityBenchmark.RunResult.load(data) {
            show(saved, suffix: "applecloud")
        } else if let data = try? Data(contentsOf: Self.testCheckpoint), let saved = try? QualityBenchmark.RunResult.load(data) {
            show(saved, suffix: "testset")
        } else if let data = try? Data(contentsOf: Self.checkpoint), let saved = try? QualityBenchmark.RunResult.load(data) {
            show(saved)
        }
    }

    func discardTestProgress() {
        try? FileManager.default.removeItem(at: Self.testCheckpoint)
        result = nil
        exportFile = nil
    }

    func discardAppleCloudProgress() {
        try? FileManager.default.removeItem(at: Self.appleCloudCheckpoint)
        result = nil
        exportFile = nil
    }

    func discardProgress() {
        try? FileManager.default.removeItem(at: Self.checkpoint)
        result = nil
        exportFile = nil
    }

    /// Replays routing with this iPhone's classifier over the bundled 0.2.0 answers. Free.
    func replay(instructions: OnDeviceClassifier.InstructionSet?) async {
        guard !isRunning, let baseline else { return }
        isRunning = true
        defer {
            isRunning = false
            progress = nil
        }
        let classifier = OnDeviceClassifier(instructionSet: instructions)
        let replayed = await QualityReplay.reroute(baseline, with: Router(classifier: classifier)) { [weak self] done, total in
            self?.progress = .init(done: done, total: total, spent: 0, current: "Routing prompt \(done + 1)")
        }
        var result = replayed
        result.classifier = "on-device classifier, \(classifier.instructionSet.id) instructions (replayed on \(BenchmarkModel.deviceName))"
        comparisons = ["heldout", "tuning"].compactMap { split in
            QualityReplay.compare(result, to: baseline, split: split).map { (split, $0) }
        }
        show(result, suffix: "replay-\(classifier.instructionSet.id)")
    }

    /// Answers the bundled results' prompts on Apple Cloud, grades them, and adds the column.
    func addAppleCloud(app: AppModel) async {
        guard !isRunning, let baseline else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let runner = QualityBenchmarkRunner(
            makeSession: { column in
                app.makeBenchmarkSession(instructions: QualityBenchmark.answerInstructions,
                                         claudeTier: column == .claudeDeep ? .deep : .standard)
            },
            judge: ModelAnswerJudge {
                app.makeBenchmarkSession(instructions: ModelAnswerJudge.instructionsForSession, claudeTier: .deep)
            },
            classifier: OnDeviceClassifier(),
            spendCap: Self.spendCap,
            checkpoint: Self.appleCloudCheckpoint,
            device: baseline.device,
            classifierName: baseline.classifier,
            judgeModelID: baseline.judgeModelID
        )
        let result = await runner.addColumn(.appleCloud, to: baseline) { [weak self] progress in
            self?.progress = progress
        }
        show(result, suffix: "applecloud")
    }

    /// - Parameter testSet: run the frozen test set, measuring only the routing rungs (no Opus
    ///   or Muse answers), instead of the benchmark.
    func run(app: AppModel, testSet: Bool = false) async {
        let cases = testSet ? testCases : cases
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
                // Muse Wonder is measured only with a Meta key; otherwise it's listed as not measured.
                app.makeBenchmarkSession(instructions: QualityBenchmark.answerInstructions,
                                         claudeTier: column == .claudeDeep ? .deep : .standard,
                                         cloud: column == .museWonder ? MuseProvider(apiKey: app.metaKey) : nil)
            },
            judge: ModelAnswerJudge {
                app.makeBenchmarkSession(instructions: ModelAnswerJudge.instructionsForSession, claudeTier: .deep)
            },
            classifier: classifier,
            spendCap: Self.spendCap,
            checkpoint: testSet ? Self.testCheckpoint : Self.checkpoint,
            device: BenchmarkModel.deviceName,
            classifierName: "on-device classifier, \(classifier.instructionSet.id) instructions",
            judgeModelID: "claude-opus-5-5",
            only: testSet ? Set(QualityBenchmark.Column.rungs) : nil
        )
        let result = await runner.run(cases) { [weak self] progress in
            self?.progress = progress
        }
        show(result, suffix: testSet ? "testset" : nil)
    }

    private func show(_ result: QualityBenchmark.RunResult, suffix: String? = nil) {
        self.result = result
        let stamp = ISO8601DateFormatter.string(from: result.startedAt, timeZone: .current, formatOptions: [.withFullDate])
        let file = URL.temporaryDirectory.appending(path: "\(stamp)-iphone-quality\(suffix.map { "-\($0)" } ?? "").json")
        if let data = try? result.encoded(), (try? data.write(to: file)) != nil {
            exportFile = file
        }
    }
}
