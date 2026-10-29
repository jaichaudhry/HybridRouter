import Foundation
import FoundationModels
import HybridRouterKitTesting
import Testing
@testable import HybridRouterKit

struct OpenRouterCatalogTests {
    /// A trimmed copy of `GET /api/v1/models`, in its October 2026 shape.
    static let catalogJSON = Data("""
    {"data": [
      {"id": "openai/gpt-5.6-luna", "name": "OpenAI: GPT-5.6 Luna", "context_length": 1050000,
       "architecture": {"input_modalities": ["file", "image", "text"], "output_modalities": ["text"]},
       "pricing": {"prompt": "0.0000002", "completion": "0.0000012", "input_cache_read": "0.00000002"},
       "supported_parameters": ["max_tokens", "structured_outputs", "tools"]},
      {"id": "openai/gpt-5.6-luna:batch", "name": "OpenAI: GPT-5.6 Luna (batch)", "context_length": 1050000,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
       "pricing": {"prompt": "0.0000001", "completion": "0.0000006"}},
      {"id": "acme/text-only", "name": "Acme: Text Only", "context_length": 32000,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
       "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
      {"id": "acme/painter", "name": "Acme: Painter", "context_length": 32000,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]},
       "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
      {"id": "openrouter/auto", "name": "Auto Router", "context_length": 2000000,
       "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]},
       "pricing": {"prompt": "-1", "completion": "-1"}}
    ]}
    """.utf8)

    @Test func keepsModelsThatAnswerInTextWithAFixedPrice() throws {
        let catalog = try OpenRouterCatalog(catalogJSON: Self.catalogJSON)
        #expect(catalog.models.map(\.id) == ["acme/text-only", "openai/gpt-5.6-luna"])
    }

    @Test func readsContextPriceAndCapabilities() throws {
        let catalog = try OpenRouterCatalog(catalogJSON: Self.catalogJSON)
        let luna = try #require(catalog.model(id: "openai/gpt-5.6-luna"))
        #expect(luna.contextLength == 1_050_000)
        #expect(abs(luna.price.input - 0.2) < 1e-9)
        #expect(abs(luna.price.cachedInput - 0.02) < 1e-9)
        #expect(abs(luna.price.output - 1.2) < 1e-9)
        #expect(luna.acceptsImages && luna.structuredOutput)
        #expect(luna.shortName == "GPT-5.6 Luna")

        let plain = try #require(catalog.model(id: "acme/text-only"))
        #expect(!plain.acceptsImages && !plain.structuredOutput)
        // No cached price listed: cached input costs the same as input.
        #expect(plain.price.cachedInput == plain.price.input)
    }

    @Test func searchMatchesEveryWordInNameOrID() throws {
        let catalog = try OpenRouterCatalog(catalogJSON: Self.catalogJSON)
        #expect(catalog.search("gpt luna").map(\.id) == ["openai/gpt-5.6-luna"])
        #expect(catalog.search("ACME").map(\.id) == ["acme/text-only"])
        #expect(catalog.search("  ").count == 2)
        #expect(catalog.search("gemini").isEmpty)
    }

    @Test func theBridgeOnlySendsWhatTheModelSupports() {
        let plain = OpenRouterModel(id: "acme/text-only", name: "Acme: Text Only", contextLength: 32_000,
                                    price: .init(input: 1, cachedInput: 1, output: 2), acceptsImages: false, structuredOutput: false)
        let capabilities = plain.bridgeModel.capabilities
        #expect(!capabilities.imageInput && !capabilities.structuredOutput)
        #expect(!capabilities.adaptiveThinking && capabilities.effortLevels.isEmpty && !capabilities.samplingParams)
        #expect(OpenRouterModel.claudeSonnet.bridgeModel.capabilities.imageInput)
    }
}

@MainActor
struct OpenRouterProviderTests {
    static let luna = OpenRouterModel(id: "openai/gpt-5.6-luna", name: "OpenAI: GPT-5.6 Luna", contextLength: 1_050_000,
                                      price: .init(input: 0.2, cachedInput: 0.02, output: 1.2), acceptsImages: true, structuredOutput: true)

    @Test func theProviderDescribesItsModel() async {
        let provider = OpenRouterProvider(apiKey: "sk-or-test", model: Self.luna)
        #expect(provider.route == .cloud)
        #expect(provider.modelID == "openai/gpt-5.6-luna")
        #expect(provider.displayName == "GPT-5.6 Luna")
        #expect(provider.availability == .available)
        #expect(await provider.contextSize() == 1_050_000)
        #expect(provider.price == Self.luna.price)
        #expect(OpenRouterProvider(apiKey: nil).availability == .unavailable(reason: "OpenRouter not configured"))
        #expect(OpenRouterProvider(apiKey: "").availability.isAvailable == false)
    }

    @Test func theAssistantBuildsAnOpenRouterProvider() {
        let provider = HybridAssistant.Cloud.openRouter(apiKey: "sk-or-test", model: Self.luna).provider
        #expect(provider is OpenRouterProvider)
        #expect(provider.modelID == "openai/gpt-5.6-luna")
        #expect(HybridAssistant.Cloud.openRouter(apiKey: "sk-or-test").provider.modelID == "anthropic/claude-sonnet-5.5")
    }

    @Test func aReplyIsPricedFromTheCatalog() async throws {
        let cloud = FakeProvider(route: .cloud, reply: "ok", usage: TokenUsage(input: 1_000_000, cachedInput: 0, output: 1_000_000, reasoning: nil),
                                 modelID: Self.luna.id, displayName: "GPT-5.6 Luna", price: Self.luna.price)
        let routed = RoutedSession(instructions: "", onDevice: FakeProvider(route: .onDevice, reply: "hi"),
                                   appleCloud: FakeProvider(route: .appleCloud, reply: "hi"), cloud: cloud,
                                   costTable: CostTable(updated: "", source: "", models: [:]))
        let result = try await routed.respond(to: "Hello", decision: .forced(.cloud))
        #expect(abs((result.metrics.estimatedCost ?? 0) - 1.4) < 1e-6)
    }

    @Test func labelsUseTheModelsOwnName() {
        let labels = RouteLabels(cloud: OpenRouterProvider(apiKey: "sk-or-test", model: Self.luna))
        #expect(labels.name(.cloud) == "GPT-5.6 Luna")
        #expect(labels.symbol(.cloud) == CloudModel.openRouter.symbolName)
        #expect(labels.name(.cloud, modelID: "openai/gpt-5.6-luna") == "GPT-5.6 Luna")
        // Replies from other models keep their own names after a switch.
        #expect(labels.name(.cloud, modelID: "google/gemini-3.8-flash") == "gemini-3.8-flash")
        #expect(labels.name(.cloud, modelID: "claude-sonnet-5-5") == "Claude")
        #expect(RouteLabels.standard.name(.cloud, modelID: "openai/gpt-5.6-luna") == "gpt-5.6-luna")
    }

    @Test func theRouteNoteNamesTheModel() {
        let note = RoutingProfile.routeNote(for: .cloud, models: [.onDevice: "Apple's on-device model", .cloud: "GPT-5.6 Luna"])
        #expect(note.contains("GPT-5.6 Luna"))
        #expect(!note.contains("Claude"))
    }

    @Test func aPrivateTurnNeverReachesOpenRouter() async throws {
        let cloud = FakeProvider(route: .cloud, reply: "advice", modelID: Self.luna.id, displayName: "GPT-5.6 Luna")
        let routed = RoutedSession(instructions: "", onDevice: FakeProvider(route: .onDevice, reply: "saved"),
                                   appleCloud: FakeProvider(route: .appleCloud, reply: "cloud"), cloud: cloud,
                                   costTable: CostTable(updated: "", source: "", models: [:]))
        let coordinator = TurnCoordinator(router: Router(classifier: FakeClassifier.always("complex")),
                                          estimator: FixedTokenEstimator(100), isOnline: { true })

        let first = await coordinator.run(.init(prompt: "Card 4111 1111 1111 1111", privacyReason: "card number"), in: routed)
        #expect(first.decision?.route == .onDevice)
        let second = await coordinator.run(.init(prompt: "Which offer should I take?"), in: routed)
        #expect(second.decision?.route == .appleCloud)
        #expect(cloud.requests.isEmpty)

        // Naming the model reaches it, with placeholders only.
        let third = await coordinator.run(.init(prompt: "Ask GPT which offer I should take"), in: routed)
        #expect(third.decision?.route == .cloud)
        let seen = try #require(cloud.requests.last)
        #expect(!String(describing: seen).contains("4111"))
    }
}

struct OpenRouterRoutingTests {
    @Test func namingTheActiveModelAsksForTheCloudRoute() {
        #expect(RouteMention.named(in: "Ask GPT what it thinks", cloudName: "GPT-5.6 Luna") == .cloud)
        #expect(RouteMention.named(in: "what does gpt-5.6 luna say?", cloudName: "GPT-5.6 Luna") == .cloud)
        #expect(RouteMention.named(in: "Let Gemini check this", cloudName: "Gemini 3.8 Flash") == .cloud)
        #expect(RouteMention.named(in: "Ask GPT what it thinks") == nil)
        #expect(RouteMention.named(in: "Ask Claude", cloudName: "GPT-5.6 Luna") == .cloud)
        // A short leading word isn't used on its own.
        #expect(RouteMention.aliases(of: "o4 Mini") == ["o4 Mini"])
        #expect(RouteMention.aliases(of: "DeepSeek V4.1 Flash") == ["DeepSeek V4.1 Flash", "DeepSeek"])
    }

    @Test func creditAndKeyFailuresFallBackWithAClearReason() {
        struct OpenRouterError: Error, CustomStringConvertible {
            var description: String { #"APIError(kind: other, message: "This request requires more credits, or fewer max_tokens.")"# }
        }
        #expect(FailureCause(OpenRouterError()) == .outOfCredits)
        let input = RoutingInput(availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available])
        let decision = RouteDecision(route: .cloud, reason: "Complex reasoning", source: .classifier)
        let next = EscalationPolicy().next(after: .outOfCredits, decision: decision, input: input, jitter: 1)
        #expect(next == .retry(RouteDecision(route: .appleCloud, reason: "Fell back: out of credits", source: .escalation)))
        // Not retried on the same route: waiting doesn't add credits or fix a key.
        let keyless = EscalationPolicy().next(after: .keyRejected, decision: decision, input: input, jitter: 1)
        #expect(keyless == .retry(RouteDecision(route: .appleCloud, reason: "Fell back: key not accepted", source: .escalation)))
    }
}
