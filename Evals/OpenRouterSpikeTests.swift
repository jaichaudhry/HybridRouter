import CoreGraphics
import Foundation
import FoundationModels
import HybridRouterKit
import Testing

/// Checks that OpenRouter's Anthropic-compatible endpoint works through the bridge for models
/// beyond Claude's: text, history, images, structured output, a cut-off reply and a bad model ID.
/// About $0.05 a run, billed to the key.
///
///     HR_RUN_OPENROUTER_SPIKE=1 swift test --package-path Evals --filter OpenRouterSpike
///
/// with `OPENROUTER_API_KEY` in Config/Secrets.xcconfig or the environment.
///
/// `HR_OPENROUTER_MODELS` (comma-separated IDs) overrides the models tried.
@MainActor
struct OpenRouterSpikeTests {
    /// From `OPENROUTER_API_KEY` in the environment or Config/Secrets.xcconfig. Never printed.
    nonisolated static let key = ProcessInfo.processInfo.environment["HR_RUN_OPENROUTER_SPIKE"] == "1"
        ? QualityEvalTests.secret("OPENROUTER_API_KEY") : nil
    nonisolated static let modelIDs = ProcessInfo.processInfo.environment["HR_OPENROUTER_MODELS"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        ?? ["anthropic/claude-sonnet-5.5", "openai/gpt-5.6-luna", "google/gemini-3.8-flash", "deepseek/deepseek-v4.1-flash"]

    @Generable struct Total {
        @Guide(description: "The total, as a number") var total: Double
        var currency: String
    }

    private func session(_ model: OpenRouterModel) throws -> RoutedSession {
        let provider = OpenRouterProvider(apiKey: Self.key, model: model)
        return RoutedSession(
            instructions: "Answer briefly.",
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: false),
            cloud: provider,
            costTable: try CostTable.bundled()
        )
    }

    private static func redSquare() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    @Test(.enabled(if: key != nil, "Set HR_RUN_OPENROUTER_SPIKE=1 and OPENROUTER_API_KEY"), arguments: modelIDs)
    func modelWorksThroughTheBridge(_ id: String) async throws {
        let catalog = try await OpenRouterCatalog.fetch()
        let model = try #require(catalog.model(id: id), "\(id) isn't in the catalog")
        let routed = try session(model)
        let cloud = RouteDecision(route: .cloud, reason: "spike", source: .rule)
        var report: [String] = ["\(id): context \(model.contextLength), images \(model.acceptsImages), structured \(model.structuredOutput)"]

        // Streaming text, usage and cost.
        var partials = 0
        let first = try await routed.respond(to: "My name is Ada. What is 17 × 3?", decision: cloud) { _ in partials += 1 }
        #expect(first.text.contains("51"), "\(id): \(first.text)")
        #expect(first.metrics.usage.input > 0 && first.metrics.usage.output > 0, "\(id): no usage")
        report.append("text: \(first.metrics.usage.input) in, \(first.metrics.usage.output) out, \(partials) partials, $\(first.metrics.estimatedCost ?? -1)")

        // History.
        let second = try await routed.respond(to: "What's my name?", decision: cloud)
        #expect(second.text.localizedCaseInsensitiveContains("Ada"), "\(id): \(second.text)")

        if model.acceptsImages {
            let image = ImageInput(Self.redSquare(), label: "square.png")
            let seen = try await routed.respond(to: "What color is this square? One word.", images: [image], decision: cloud)
            #expect(seen.text.localizedCaseInsensitiveContains("red"), "\(id): \(seen.text)")
            report.append("image: \(seen.text.prefix(40))")
        }

        if model.structuredOutput {
            let structured = try await routed.respond(to: "Lunch was 12.50 USD and coffee 3.25 USD. Total?",
                                                      decision: cloud, schema: Total.generationSchema)
            report.append("structured: \(structured.text.prefix(80))")
            #expect(structured.text.contains("15.75"), "\(id): \(structured.text)")
        }
        print(report.joined(separator: "\n  "))
    }

    @Test(.enabled(if: key != nil, "Set HR_RUN_OPENROUTER_SPIKE=1 and OPENROUTER_API_KEY"))
    func anUnknownModelFailsClearly() async throws {
        let bogus = OpenRouterModel(id: "nobody/no-such-model", name: "None", contextLength: 8_000,
                                    price: .init(input: 0, cachedInput: 0, output: 0), acceptsImages: false, structuredOutput: false)
        let routed = try session(bogus)
        do {
            _ = try await routed.respond(to: "Hi", decision: RouteDecision(route: .cloud, reason: "spike", source: .rule))
            Issue.record("Expected an error")
        } catch {
            print("unknown model: \(error)")
        }
    }

    @Test(.enabled(if: key != nil, "Set HR_RUN_OPENROUTER_SPIKE=1 and OPENROUTER_API_KEY"))
    func aBadKeyFailsClearly() async throws {
        let provider = OpenRouterProvider(apiKey: "sk-or-invalid", model: .claudeSonnet)
        let routed = RoutedSession(instructions: "Answer briefly.", onDevice: OnDeviceProvider(),
                                   appleCloud: AppleCloudProvider(isEnabled: false), cloud: provider,
                                   costTable: try CostTable.bundled())
        do {
            _ = try await routed.respond(to: "Hi", decision: RouteDecision(route: .cloud, reason: "spike", source: .rule))
            Issue.record("Expected an error")
        } catch {
            print("bad key: \(error)")
        }
    }
}
