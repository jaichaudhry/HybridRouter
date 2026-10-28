import HybridRouterKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings › Developer › Conversations: the multi-turn benchmark on this iPhone. Each
/// conversation runs start to finish under the router, always on-device and always Claude, and
/// Claude Opus grades every turn. Progress is saved after every conversation, so a run can stop
/// and resume.
struct MultiTurnEvalView: View {
    let app: AppModel
    @State private var model = MultiTurnEvalModel()
    /// `.task(id:)` cancels a run when the screen closes, so paid requests stop too.
    @State private var runToken: UUID?
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                if let dataset = model.dataset {
                    LabeledContent("Conversations", value: "\(dataset.conversations.count) (\(dataset.conversations.filter { $0.split == "heldout" }.count) held out)")
                    LabeledContent("Turns", value: "\(dataset.conversations.map(\.turns.count).reduce(0, +))")
                }
                LabeledContent("Spend cap", value: String(format: "$%.2f", MultiTurnEvalModel.spendCap))
                if model.isRunning {
                    ProgressView(value: Double(model.progress?.done ?? 0), total: Double(max(model.progress?.total ?? 1, 1))) {
                        Text("\(model.progress?.done ?? 0) of \(model.progress?.total ?? 0) · \(String(format: "$%.2f", model.progress?.spent ?? 0)) spent")
                            .monospacedDigit()
                    } currentValueLabel: {
                        Text(model.progress?.current ?? "Starting…").lineLimit(2)
                    }
                    Button("Stop", role: .destructive) { runToken = nil }
                } else if model.dataset != nil {
                    Button(model.hasSavedProgress ? "Resume" : "Run benchmark") { runToken = UUID() }
                    if model.hasSavedProgress {
                        Button("Start over", role: .destructive) { model.discardProgress() }
                    }
                    Button("Continue from a results file…") { isImporting = true }
                }
                if let importError = model.importError {
                    Text(importError).foregroundStyle(.red)
                }
            } footer: {
                Text("Runs 36 conversations of 4–6 turns under the router, always on-device and always Claude Sonnet (failure conversations on the router only), and has Opus grade every turn. Calls are billed to your Claude key: about $10–15, about an hour, and it stops before passing the cap. Keep the app open; the screen stays on while it runs.")
            }

            if let result = model.result, let dataset = model.dataset {
                if result.stoppedAtSpendCap {
                    Section {
                        Label("Stopped at the spend cap. Progress is saved.", systemImage: "dollarsign.circle")
                    }
                }
                ForEach([nil, "heldout"] as [String?], id: \.self) { split in
                    let report = MultiTurnReport(result, dataset: dataset, split: split)
                    if report.conversations > 0 {
                        MultiTurnReportSection(report: report, title: split == nil ? "All conversations" : "Held-out")
                    }
                }
                Section {
                    if let file = model.exportFile {
                        ShareLink("Share results (JSON)", item: file)
                    }
                    ShareLink("Share summary (Markdown)", item: model.markdown)
                } footer: {
                    Text("\(result.runs.count) conversation runs · \(String(format: "$%.2f", result.spent)) spent, judging included")
                }
            }
        }
        .navigationTitle("Conversations")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { picked in
            if case .success(let url) = picked { model.importResults(from: url) }
        }
        .task(id: runToken) {
            guard runToken != nil else { return }
            await model.run(app: app)
            runToken = nil
        }
        .onAppear { model.loadSaved() }
    }
}

private struct MultiTurnReportSection: View {
    let report: MultiTurnReport
    let title: String

    var body: some View {
        Section("\(title) (\(report.conversations))") {
            ForEach(report.strategies, id: \.strategy) { summary in
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.strategy.displayName)
                        .fontWeight(summary.strategy == .router ? .semibold : .regular)
                    Text("\(percent(summary.passRate)) of turns passed · \(percent(summary.conversationPassRate)) of conversations · \(String(format: "$%.3f", summary.costPerConversation)) each · \(percent(summary.onDeviceShare)) on the phone")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            LabeledContent("Follow-ups stayed", value: "\(report.followUps.stayed) of \(report.followUps.count)")
            LabeledContent("Privacy leaks", value: "\(report.privacy.leaks)")
                .foregroundStyle(report.privacy.leaks == 0 ? Color.primary : Color.red)
            LabeledContent("After a private turn", value: "\(percent(report.privacy.afterPrivateRouterPassRate)) vs \(percent(report.privacy.afterPrivateClaudePassRate)) on Claude")
            LabeledContent("Long chats moved up", value: "\(report.longChats.movedUp)")
            LabeledContent("Recall on the router", value: percent(report.longChats.recallPassRate[.router]))
            LabeledContent("Failures answered", value: "\(report.failures.answered) of \(report.failures.faultedTurns)")
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
    }
}

@MainActor
@Observable
final class MultiTurnEvalModel {
    static let spendCap = 20.0
    private static let checkpoint = URL.cachesDirectory.appending(path: "multiturn-benchmark-checkpoint.json")

    let dataset: MultiTurnBenchmark.Dataset?
    private(set) var isRunning = false
    private(set) var progress: MultiTurnBenchmarkRunner.Progress?
    private(set) var result: MultiTurnBenchmark.RunResult?
    private(set) var exportFile: URL?
    private(set) var importError: String?

    init() {
        dataset = Bundle.main.url(forResource: "multiturn_benchmark", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? MultiTurnBenchmark.Dataset.load($0) }
    }

    var hasSavedProgress: Bool { FileManager.default.fileExists(atPath: Self.checkpoint.path()) }

    var markdown: String {
        guard let result, let dataset else { return "" }
        let header = """
            # Multi-turn benchmark on \(result.device)

            \(result.runs.count) conversation runs, \(String(format: "$%.2f", result.spent)) spent. Router: \(result.classifier). \
            Cloud model: \(result.cloudModelID). Routes available: \(result.availableRoutes.map(\.displayName).joined(separator: ", ")). \
            On-device context: \(result.onDeviceContextSize.map { "\($0) tokens" } ?? "unknown"). Judge: \(result.judgeModelID).
            """
        let sections = [(nil, "All conversations"), ("heldout", "Held-out"), ("tuning", "Tuning")].compactMap { split, title in
            let report = MultiTurnReport(result, dataset: dataset, split: split)
            return report.conversations > 0 ? report.markdown(title: title) : nil
        }
        return ([header] + sections).joined(separator: "\n\n")
    }

    func loadSaved() {
        guard result == nil, let data = try? Data(contentsOf: Self.checkpoint),
              let saved = try? MultiTurnBenchmark.RunResult.load(data) else { return }
        show(saved)
    }

    /// Makes a saved results file the progress to resume from: a later run only does the
    /// conversations and strategies it doesn't have. Used to reuse unchanged baseline runs.
    func importResults(from url: URL) {
        importError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let imported = try MultiTurnBenchmark.RunResult.load(data)
            try data.write(to: Self.checkpoint, options: .atomic)
            show(imported)
        } catch {
            importError = "Couldn't read that file as benchmark results: \(error.localizedDescription)"
        }
    }

    func discardProgress() {
        try? FileManager.default.removeItem(at: Self.checkpoint)
        result = nil
        exportFile = nil
    }

    func run(app: AppModel) async {
        guard !isRunning, let dataset else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let runner = MultiTurnBenchmarkRunner(
            dataset: dataset,
            makeSession: { _, tap in app.makeMultiTurnSession(tap: tap) },
            makeCoordinator: { app.makeMultiTurnCoordinator() },
            judge: ModelAnswerJudge {
                app.makeBenchmarkSession(instructions: ModelAnswerJudge.instructionsForSession, claudeTier: .deep)
            },
            spendCap: Self.spendCap,
            checkpoint: Self.checkpoint,
            device: BenchmarkModel.deviceName,
            classifierName: "on-device classifier, \(OnDeviceClassifier().instructionSet.id) instructions + exact-answer detector",
            judgeModelID: "claude-opus-5-5"
        )
        let result = await runner.run { [weak self] progress in
            self?.progress = progress
        }
        show(result)
    }

    private func show(_ result: MultiTurnBenchmark.RunResult) {
        self.result = result
        let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        let file = URL.temporaryDirectory.appending(path: "\(stamp)-iphone-multiturn.json")
        if let data = try? result.encoded(), (try? data.write(to: file)) != nil {
            exportFile = file
        }
    }
}
