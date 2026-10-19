import Foundation
import HybridRouterKit
import HybridRouterKitTesting
import HybridRouterKitVoice
import Testing

@MainActor
struct VoiceInputTests {
    @Test func voiceInputIsTaughtTheAssistantsModelNames() {
        let assistant = HybridAssistant(
            instructions: "",
            onDevice: FakeProvider(route: .onDevice, reply: "x"),
            appleCloud: FakeProvider(route: .appleCloud, reply: "x"),
            cloud: FakeProvider(route: .cloud, reply: "x", modelID: "gemini-3", displayName: "Gemini"),
            router: Router(classifier: FakeClassifier.always("simple")),
            estimator: FixedTokenEstimator(10),
            isOnline: { true }
        )
        let voice = VoiceInput(for: assistant, vocabulary: ["Kyoto"])
        #expect(voice.vocabulary.contains("Gemini"))
        #expect(voice.vocabulary.contains("Claude"))
        #expect(voice.vocabulary.contains("Apple Cloud"))
        #expect(voice.vocabulary.contains("Kyoto"))
        #expect(voice.state == .idle)
        #expect(voice.text.isEmpty)
    }

    /// Speaks prompts with macOS `say` and transcribes the audio with Apple's speech model.
    /// Opt-in: the model may need downloading. `HR_RUN_SPEECH_TEST=1 swift test --filter VoiceInput`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HR_RUN_SPEECH_TEST"] == "1"))
    func transcribesSpokenPromptsOnDevice() async throws {
        let prompts = [
            "Ask Claude to compare these two job offers.",
            "Plan three days in Kyoto with a day trip to Nara.",
            "What is 17 times 24?",
        ]
        for prompt in prompts {
            let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", url.path, prompt]
            try say.run()
            say.waitUntilExit()
            let transcript = try await VoiceInput.transcribe(
                audioFile: url, vocabulary: VoiceInput.routeNames() + ["Kyoto", "Nara"], locale: Locale(identifier: "en_US")
            )
            let score = TranscriptScore(reference: prompt, transcript: transcript.text)
            #expect(score.wordErrorRate <= 0.2, "\(prompt) → \(transcript.text)")
            #expect(transcript.audioSeconds > 0.5)
        }
    }
}
