import Foundation
import FoundationModels
import HybridRouterKit
import Testing

/// The answer-quality benchmark on a Mac: every prompt in quality_benchmark.json answered on
/// each route, graded by Claude Opus, and the router scored on quality versus cost.
///
/// It calls Claude, so it costs money (about $9 for the full set) and only runs when asked:
///
///     HR_RUN_QUALITY_EVAL=1 swift test --package-path Evals --filter QualityEval
///
/// The Claude key comes from ANTHROPIC_API_KEY, or else Config/Secrets.xcconfig (gitignored,
/// the same file the app's Debug builds read).
///
/// Optional: `HR_QUALITY_LIMIT=5` answers only the first 5 prompts (a smoke run), and
/// `HR_QUALITY_SPEND_CAP=15` sets the cap in USD (default 15). Results go to Evals/results/.
/// Progress is saved after every prompt, so an interrupted run resumes; delete
/// Evals/results/checkpoint-mac.json to start over.
///
/// The Mac's on-device model is a different variant from recent iPhones', so the headline
/// numbers come from the in-app run on an iPhone (Settings › Developer › Answer quality).
@MainActor
struct QualityEvalTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    /// From ANTHROPIC_API_KEY, or else the gitignored Config/Secrets.xcconfig the app uses.
    nonisolated static let apiKey = secret("ANTHROPIC_API_KEY")
    /// Meta's Model API key, for the Muse Wonder column. Same lookup as `apiKey`.
    nonisolated static let metaKey = secret("META_API_KEY")

    /// A key from the environment, or else from Config/Secrets.xcconfig. Never printed.
    nonisolated static func secret(_ name: String) -> String? {
        if let key = environment[name], !key.isEmpty { return key }
        let secrets = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../Config/Secrets.xcconfig").standardized
        guard let text = try? String(contentsOf: secrets, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix(name) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.first?.trimmingCharacters(in: .whitespaces) == name else { continue }
            let value = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
            if parts.count == 2, !value.isEmpty { return value }
        }
        return nil
    }
    nonisolated static let isRequested = environment["HR_RUN_QUALITY_EVAL"] == "1"

    static let resultsDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "results")

    static func cases() throws -> [QualityBenchmark.Case] {
        let url = try #require(Bundle.module.url(forResource: "quality_benchmark", withExtension: "json"))
        let all = try QualityBenchmark.load(Data(contentsOf: url))
        guard let limit = environment["HR_QUALITY_LIMIT"].flatMap(Int.init) else { return all }
        return Array(all.prefix(limit))
    }

    static func claudeAuth() -> ClaudeAuth {
        ClaudeAuthSource.resolve(
            environment: ClaudeAuthEnvironment(
                clientID: nil, isPhysicalDevice: false, isAppAttestSupported: false,
                developerKey: apiKey, allowsDeveloperKey: true
            ),
            userKey: nil
        )
    }

    /// A session whose cloud slot serves the column's model: Sonnet, Opus, or Muse Wonder (which
    /// is measured only when a Meta key is set).
    static func session(for column: QualityBenchmark.Column) -> RoutedSession {
        let cloud: any ModelProvider = switch column {
        case .claudeDeep: ClaudeProvider(auth: claudeAuth(), tier: .deep)
        case .museWonder: MuseProvider(apiKey: metaKey)
        default: ClaudeProvider(auth: claudeAuth(), tier: .standard)
        }
        return RoutedSession(
            instructions: QualityBenchmark.answerInstructions,
            onDevice: OnDeviceProvider(),
            // No Private Cloud Compute entitlement on a Mac, so Apple Cloud isn't measured.
            appleCloud: AppleCloudProvider(isEnabled: false),
            claude: cloud,
            costTable: (try? CostTable.bundled()) ?? CostTable(updated: "", source: "", models: [:])
        )
    }

    /// Claude Opus as the judge, for every column.
    static func judge() throws -> ModelAnswerJudge {
        let costTable = try CostTable.bundled()
        let auth = claudeAuth()
        return ModelAnswerJudge {
            RoutedSession(
                instructions: ModelAnswerJudge.instructionsForSession,
                onDevice: OnDeviceProvider(), appleCloud: AppleCloudProvider(isEnabled: false),
                claude: ClaudeProvider(auth: auth, tier: .deep), costTable: costTable
            )
        }
    }

    @Test func benchmarkIsWellFormed() throws {
        let cases = try Self.cases()
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.allSatisfy { ["tuning", "heldout"].contains($0.split) })
        if Self.environment["HR_QUALITY_LIMIT"] == nil {
            #expect(cases.filter { $0.split == "heldout" }.count == 150)
        }
    }

    @Test(.enabled(if: isRequested && apiKey != nil && SystemLanguageModel.default.isAvailable,
                   "Set HR_RUN_QUALITY_EVAL=1 and a Claude key (ANTHROPIC_API_KEY or Config/Secrets.xcconfig); needs the on-device model"))
    func answerQuality() async throws {
        let classifier = OnDeviceClassifier()
        let spendCap = Self.environment["HR_QUALITY_SPEND_CAP"].flatMap(Double.init) ?? 15
        try FileManager.default.createDirectory(at: Self.resultsDirectory, withIntermediateDirectories: true)

        let runner = QualityBenchmarkRunner(
            makeSession: Self.session(for:),
            judge: try Self.judge(),
            classifier: classifier,
            spendCap: spendCap,
            checkpoint: Self.resultsDirectory.appending(path: "checkpoint-mac.json"),
            device: "Mac, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), on-device \(SystemLanguageModel.default.variant)",
            classifierName: "on-device classifier, \(classifier.instructionSet.id) instructions",
            judgeModelID: "claude-opus-5-5"
        )
        let result = await runner.run(try Self.cases()) { progress in
            if let current = progress.current {
                print("QUALITY \(progress.done + 1)/\(progress.total) $\(String(format: "%.2f", progress.spent)) \(current.prefix(60))")
            }
        }

        let stamp = ISO8601DateFormatter.string(from: result.startedAt, timeZone: .current, formatOptions: [.withFullDate])
        let base = Self.resultsDirectory.appending(path: "\(stamp)-mac")
        try result.encoded().write(to: base.appendingPathExtension("json"))
        let markdown = [
            "# Answer quality on a Mac (\(result.cases.count) prompts, $\(String(format: "%.2f", result.spent)))",
            QualityReport(result, split: "heldout").markdown(title: "Held-out"),
            QualityReport(result, split: "tuning").markdown(title: "Tuning"),
        ].joined(separator: "\n\n")
        try markdown.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        print(markdown)

        #expect(result.spent <= spendCap)
        #expect(!result.cases.isEmpty)
    }

    /// Adds a Muse Wonder column to a saved run: each prompt answered by Meta's Muse Wonder and
    /// graded by the same Claude Opus judge, leaving the other columns as they were. Writes
    /// `<run>-muse.json` and `.md` next to the input. Progress is saved after every prompt.
    ///
    ///     HR_RUN_MUSE_EVAL=1 HR_QUALITY_RESULTS=Evals/results/2026-10-14-iphone-quality.json \
    ///         swift test --package-path Evals --filter museWonderColumn
    @Test(.enabled(if: environment["HR_RUN_MUSE_EVAL"] == "1" && environment["HR_QUALITY_RESULTS"] != nil
                   && apiKey != nil && metaKey != nil,
                   "Set HR_RUN_MUSE_EVAL=1, HR_QUALITY_RESULTS, and Claude and Meta keys"))
    func museWonderColumn() async throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = try #require(Self.environment["HR_QUALITY_RESULTS"])
        let input = path.hasPrefix("/") ? URL(filePath: path) : repo.appending(path: path)
        let run = try QualityBenchmark.RunResult.load(Data(contentsOf: input))
        let spendCap = Self.environment["HR_QUALITY_SPEND_CAP"].flatMap(Double.init) ?? 10

        let runner = QualityBenchmarkRunner(
            makeSession: Self.session(for:),
            judge: try Self.judge(),
            classifier: OnDeviceClassifier(),
            spendCap: spendCap,
            checkpoint: Self.resultsDirectory.appending(path: "checkpoint-muse.json"),
            device: run.device, classifierName: run.classifier, judgeModelID: run.judgeModelID
        )
        let result = await runner.addColumn(.museWonder, to: run) { progress in
            if let current = progress.current {
                print("MUSE \(progress.done + 1)/\(progress.total) $\(String(format: "%.2f", progress.spent)) \(current.prefix(60))")
            }
        }

        let base = input.deletingPathExtension().deletingLastPathComponent()
            .appending(path: input.deletingPathExtension().lastPathComponent + "-muse")
        try result.encoded().write(to: base.appendingPathExtension("json"))
        let markdown = [
            "# Answer quality on \(result.device), with Muse Wonder (\(result.cases.count) prompts, $\(String(format: "%.2f", result.spent)) in all)",
            QualityReport(result, split: "heldout").markdown(title: "Held-out"),
            QualityReport(result, split: "tuning").markdown(title: "Tuning"),
        ].joined(separator: "\n\n")
        try markdown.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        print(markdown)

        let failures = result.cases.compactMap { $0.answer(.museWonder)?.failure }
        #expect(failures.isEmpty, "Muse Wonder failed on \(failures.count) prompts: \(Set(failures))")
    }

    /// Re-reports a saved run without calling any model: writes its Markdown summary next to it
    /// and the held-out chart to docs/quality-pareto.svg.
    ///
    ///     HR_QUALITY_RESULTS=Evals/results/2026-10-14-iphone-quality.json HR_QUALITY_DEVICE="iPhone 17 Pro Max" \
    ///         swift test --package-path Evals --filter qualityChart
    ///
    /// `HR_QUALITY_DEVICE` optionally names the device in the chart's caption.
    @Test(.enabled(if: environment["HR_QUALITY_RESULTS"] != nil, "Set HR_QUALITY_RESULTS to a results JSON"))
    func qualityChart() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = try #require(Self.environment["HR_QUALITY_RESULTS"])
        let file = path.hasPrefix("/") ? URL(filePath: path) : repo.appending(path: path)
        let run = try QualityBenchmark.RunResult.load(Data(contentsOf: file))
        let heldOut = QualityReport(run, split: "heldout")
        #expect(heldOut.count > 0)

        let markdown = [
            "# Answer quality on \(run.device) (\(run.cases.count) prompts, $\(String(format: "%.2f", run.spent)))",
            heldOut.markdown(title: "Held-out"),
            QualityReport(run, split: "tuning").markdown(title: "Tuning"),
        ].joined(separator: "\n\n")
        try markdown.write(to: file.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)

        let device = Self.environment["HR_QUALITY_DEVICE"] ?? run.device
        let caption = "\(heldOut.count) held-out prompts, on-device answers from an \(device); every answer graded by Claude Opus 5.5."
        try QualityChart.svg(heldOut, caption: caption)
            .write(to: repo.appending(path: "docs/quality-pareto.svg"), atomically: true, encoding: .utf8)
    }
}
