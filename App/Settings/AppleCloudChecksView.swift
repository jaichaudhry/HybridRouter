import ChatUI
import FoundationModels
import HybridRouterKit
import SwiftUI
import UIKit
#if canImport(_Vision_FoundationModels)
import Vision
#endif

/// Exercises Apple's Private Cloud Compute model directly, whatever the build config, so the
/// first build with the entitlement can be checked in one tap. Without the entitlement it
/// records how Apple Cloud fails, which Apple doesn't document.
struct AppleCloudChecksView: View {
    let app: AppModel
    @State private var checks = AppleCloudChecks()
    @State private var runToken: UUID?

    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: BenchmarkModel.deviceName)
                LabeledContent("Entitlement in this build", value: app.isAppleCloudEnabled ? "Yes" : "No")
                Button(checks.isRunning ? "Running…" : "Run checks") { runToken = UUID() }
                    .disabled(checks.isRunning)
            } footer: {
                Text("Talks to Private Cloud Compute directly. The three-route check also sends two short messages to Claude if it's configured.")
            }

            if !checks.results.isEmpty {
                Section("Results") {
                    ForEach(checks.results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Label {
                                Text(result.name)
                            } icon: {
                                Image(systemName: result.outcome.symbolName)
                                    .foregroundStyle(result.outcome.color)
                            }
                            .font(.subheadline.weight(.semibold))
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(result.name), \(result.outcome.rawValue). \(result.detail)")
                    }
                }
                if !checks.isRunning {
                    Section {
                        ShareLink("Share report", item: checks.report(app: app))
                    }
                }
            }
        }
        .navigationTitle("Apple Cloud checks")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: runToken) {
            guard runToken != nil else { return }
            await checks.run(app: app)
        }
        .onAppear { checks.restoreAfterCrash() }
    }
}

@MainActor
@Observable
final class AppleCloudChecks {
    struct Result: Identifiable {
        enum Outcome: String {
            case pass, fail, info

            var symbolName: String {
                switch self {
                case .pass: "checkmark.circle.fill"
                case .fail: "xmark.circle.fill"
                case .info: "info.circle.fill"
                }
            }

            var color: Color {
                switch self {
                case .pass: .green
                case .fail: .red
                // Not blue: blue would read as the Apple Cloud route.
                case .info: .secondary
                }
            }
        }

        let id = UUID()
        let name: String
        let outcome: Outcome
        let detail: String
    }

    private(set) var results: [Result] = []
    private(set) var isRunning = false

    // Some Apple Cloud calls can crash the app inside FoundationModels instead of throwing (seen
    // without the entitlement), so progress is saved before each check and shown after a relaunch.
    // A file written before each check, not UserDefaults, which may not reach disk before a crash.
    private static let progressURL = URL.cachesDirectory.appending(path: "apple-cloud-checks-progress.json")

    private struct Progress: Codable {
        var running: String
        var finished: [[String]]
    }

    func run(app: AppModel) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            try? FileManager.default.removeItem(at: Self.progressURL)
        }
        results = []

        let cloud = PrivateCloudComputeLanguageModel()
        step("Availability and quota") { checkAvailability(cloud) }
        step("Capabilities") { checkCapabilities(cloud) }
        await step("Context size") { await checkContextSize(cloud) }
        // Without the entitlement, the first real request trips an assertion inside
        // FoundationModels and crashes the app instead of throwing (confirmed on iOS 27.0.1:
        // the three checks above pass, then "Simple reply" crashes). So only run requests in
        // builds that have it.
        guard app.isAppleCloudEnabled else {
            for name in ["Simple reply", "Three-route hop", "Image + OCR", "Structured output"] {
                add(name, .info, "Skipped: this build doesn't have the Private Cloud Compute entitlement. Without it, any request crashes the app inside FoundationModels.")
            }
            return
        }
        await step("Simple reply") { await checkSimpleReply(cloud) }
        if Task.isCancelled { return }
        await step("Three-route hop") { await checkHop(app: app) }
        if Task.isCancelled { return }
        await step("Image + OCR") { await checkImage(app: app) }
        if Task.isCancelled { return }
        await step("Structured output") { await checkStructuredOutput(cloud) }
    }

    /// Shows what a crashed run got through, and where it stopped.
    func restoreAfterCrash() {
        guard !isRunning,
              let data = try? Data(contentsOf: Self.progressURL),
              let progress = try? JSONDecoder().decode(Progress.self, from: data) else { return }
        try? FileManager.default.removeItem(at: Self.progressURL)
        results = progress.finished.compactMap { saved in
            guard saved.count == 3, let outcome = Result.Outcome(rawValue: saved[1]) else { return nil }
            return Result(name: saved[0], outcome: outcome, detail: saved[2])
        }
        add(progress.running, .fail, "The app crashed during this check, inside FoundationModels. The checks above finished.")
    }

    private func step(_ name: String, _ check: () -> Void) {
        saveProgress(running: name)
        check()
    }

    private func step(_ name: String, _ check: () async -> Void) async {
        saveProgress(running: name)
        await check()
    }

    private func saveProgress(running: String) {
        let progress = Progress(running: running, finished: results.map { [$0.name, $0.outcome.rawValue, $0.detail] })
        if let data = try? JSONEncoder().encode(progress) {
            try? data.write(to: Self.progressURL, options: .atomic)
        }
    }

    // MARK: Checks

    private func checkAvailability(_ cloud: PrivateCloudComputeLanguageModel) {
        let availability: String = switch cloud.availability {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "unavailable: device not eligible"
        case .unavailable(.systemNotReady): "unavailable: system not ready"
        case .unavailable(let other): "unavailable: \(other)"
        }
        let quota: String = switch cloud.quotaUsage.status {
        case .belowLimit(let below): below.isApproachingLimit ? "approaching the daily limit" : "below the daily limit"
        case .limitReached: "daily limit reached"
        @unknown default: "unknown"
        }
        let reset = cloud.quotaUsage.resetDate.map { ", resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        add("Availability and quota", cloud.isAvailable ? .pass : .fail, "\(availability); quota \(quota)\(reset)")
    }

    private func checkCapabilities(_ cloud: PrivateCloudComputeLanguageModel) {
        let capabilities = cloud.capabilities
        let names: [(String, LanguageModelCapabilities.Capability)] = [
            ("vision", .vision), ("tool calling", .toolCalling),
            ("structured output", .guidedGeneration), ("reasoning", .reasoning),
        ]
        let supported = names.filter { capabilities.contains($0.1) }.map(\.0)
        let missing = names.filter { !capabilities.contains($0.1) }.map(\.0)
        add("Capabilities", .info, "Supports: \(supported.joined(separator: ", ").ifEmpty("none")). Missing: \(missing.joined(separator: ", ").ifEmpty("none")).")
    }

    private func checkContextSize(_ cloud: PrivateCloudComputeLanguageModel) async {
        do {
            let size = try await cloud.contextSize
            add("Context size", .pass, "\(size) tokens (documented: 32,768)")
        } catch {
            add("Context size", .fail, Self.describe(error))
        }
    }

    private func checkSimpleReply(_ cloud: PrivateCloudComputeLanguageModel) async {
        let session = LanguageModelSession(model: cloud)
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: Duration?
        do {
            var text = ""
            for try await snapshot in session.streamResponse(to: "Explain how a refrigerator works in about 100 words.") {
                if firstToken == nil, !snapshot.content.isEmpty { firstToken = start.duration(to: clock.now) }
                text = snapshot.content
            }
            let total = start.duration(to: clock.now)
            let output = session.usage.output.totalTokenCount
            let streaming = total - (firstToken ?? .zero)
            let rate = streaming > .zero ? Double(output) / streaming.seconds : 0
            add("Simple reply", .pass, "First token \(Self.ms(firstToken)), \(String(format: "%.0f", rate)) tok/s, \(session.usage.input.totalTokenCount) in / \(output) out (reasoning \(session.usage.output.reasoningTokenCount), cached \(session.usage.input.cachedTokenCount)). \"\(text.prefix(80))…\"")
        } catch {
            add("Simple reply", .fail, Self.describe(error))
        }
    }

    /// The M1 acceptance check with the real models: Apple Cloud must still know turn 1 after
    /// the conversation went through the on-device model and Claude.
    private func checkHop(app: AppModel) async {
        let claude = ClaudeProvider(auth: app.claudeAuth)
        let session = RoutedSession(
            instructions: "Answer in as few words as possible.",
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: true),
            claude: claude,
            costTable: app.prices
        )
        var hops: [Route] = [.onDevice, .appleCloud]
        if claude.availability.isAvailable { hops.append(.claude) }
        hops.append(.appleCloud)
        let prompts = ["My favorite city is Kyoto. Reply OK.", "Reply OK.", "Reply OK.", "What's my favorite city? One word."]
        var path: [String] = []
        for (index, route) in hops.enumerated() {
            let prompt = index == hops.count - 1 ? prompts[3] : prompts[index]
            do {
                let result = try await session.respond(to: prompt, decision: .forced(route))
                path.append(route.displayName)
                if index == hops.count - 1 {
                    let remembered = result.text.localizedCaseInsensitiveContains("kyoto")
                    add("Three-route hop", remembered ? .pass : .fail,
                        "\(path.joined(separator: " → ")). Final answer: \"\(result.text.prefix(60))\"\(claude.availability.isAvailable ? "" : " (Claude not configured, so skipped)")")
                }
            } catch {
                add("Three-route hop", .fail, "Failed at \(route.displayName) after \(path.joined(separator: " → ").ifEmpty("start")): \(Self.describe(error))")
                return
            }
        }
    }

    private func checkImage(app: AppModel) async {
        #if canImport(_Vision_FoundationModels)
        let tools: [any Tool] = [OCRTool()]
        #else
        let tools: [any Tool] = []
        #endif
        let session = RoutedSession(
            instructions: "Read attached images with getText, using the image's label, and answer from what it returns.",
            appleOnlyTools: tools,
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: true),
            claude: ClaudeProvider(auth: .off),
            costTable: app.prices
        )
        do {
            let image = ImageInput(Self.receiptImage(), label: "check-receipt")
            let result = try await session.respond(to: "What is the total on this receipt?", images: [image],
                                                   decision: .forced(.appleCloud), isPrivate: true)
            let calls = session.transcript.filter { if case .toolCalls = $0 { true } else { false } }.count
            let correct = result.text.contains("19.77")
            add("Image + OCR", correct ? .pass : .fail,
                "\(tools.isEmpty ? "No OCR tool in this SDK. " : "")\(calls) tool call(s). Answer: \"\(result.text.prefix(80))\" (expected $19.77)")
        } catch {
            add("Image + OCR", .fail, Self.describe(error))
        }
    }

    private func checkStructuredOutput(_ cloud: PrivateCloudComputeLanguageModel) async {
        let session = LanguageModelSession(model: cloud)
        do {
            let response = try await session.respond(
                to: "Make a 2-day Kyoto itinerary for a family, 3 stops a day.",
                generating: Itinerary.self
            )
            let days = response.content.days.count
            let items = response.content.days.map(\.items.count).reduce(0, +)
            add("Structured output", days >= 2 ? .pass : .fail, "\"\(response.content.title)\": \(days) days, \(items) stops")
        } catch {
            add("Structured output", .fail, Self.describe(error))
        }
    }

    // MARK: Helpers

    private func add(_ name: String, _ outcome: Result.Outcome, _ detail: String) {
        results.append(Result(name: name, outcome: outcome, detail: detail))
    }

    /// The error's type and cause, since which error Apple throws (e.g. without the
    /// entitlement) is part of what these checks find out.
    static func describe(_ error: any Error) -> String {
        let failure = (error as? RoutedSession.StepFailure)?.underlying ?? error
        return "\(String(reflecting: type(of: failure))) (\(FailureCause(failure).label)): \(failure.localizedDescription)"
    }

    static func ms(_ duration: Duration?) -> String {
        duration.map { "\(Int($0.seconds * 1000)) ms" } ?? "—"
    }

    static func receiptImage() -> CGImage {
        let size = CGSize(width: 600, height: 500)
        let lines = ["ACME MARKET", "2026-10-08", "", "Bananas        $1.29", "Oat milk       $4.49", "Coffee beans  $13.99", "", "TOTAL         $19.77"]
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 32, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 30 + CGFloat(index) * 52), withAttributes: attributes)
            }
        }
        return image.cgImage!
    }

    func report(app: AppModel) -> String {
        var lines = [
            "HybridRouter Apple Cloud checks",
            "Device: \(BenchmarkModel.deviceName)",
            "Entitlement in this build: \(app.isAppleCloudEnabled ? "yes" : "no")",
        ]
        lines += results.map { "[\($0.outcome.rawValue)] \($0.name): \($0.detail)" }
        return lines.joined(separator: "\n")
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
