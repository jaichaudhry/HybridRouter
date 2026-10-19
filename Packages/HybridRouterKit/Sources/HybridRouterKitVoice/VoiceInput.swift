import AVFAudio
import Foundation
import Observation
import Speech

/// Speech-to-text for a routed conversation, entirely on the device: the audio never leaves it.
///
/// ```swift
/// let voice = VoiceInput(for: assistant)
/// try await voice.start()              // voice.text updates while the user speaks
/// let transcript = await voice.stop()
/// let reply = await assistant.respond(to: transcript.text)
/// ```
///
/// The transcript is plain text, so it goes through the same on-device privacy check and
/// routing as a typed message. Uses Apple's `SpeechTranscriber`, which streams words as they're
/// spoken; the speech model is downloaded once per language if it isn't on the device yet.
///
/// An app using this needs `NSMicrophoneUsageDescription` in its Info.plist.
@MainActor
@Observable
public final class VoiceInput {
    /// Apple's speech-to-text models.
    public enum Model: String, CaseIterable, Codable, Sendable {
        /// `SpeechTranscriber`: Apple's newer model, the one behind Notes and Voice Memos
        /// transcription. Fast and accurate on clear speech.
        case speech
        /// `DictationTranscriber`: the keyboard dictation model, for languages or devices the
        /// newer one doesn't support.
        case dictation
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Downloading the speech model or starting the microphone.
        case preparing
        case listening
        /// Settling the last words after `stop()`.
        case finishing
    }

    /// A finished transcription.
    public struct Transcript: Equatable, Sendable {
        public var text: String
        /// Seconds of audio heard.
        public var audioSeconds: Double
        /// Seconds from `start()` to the first words on screen, if any arrived.
        public var firstTextAfter: Double?
        /// Seconds from `stop()` to the final text.
        public var finalAfterStop: Double
    }

    public enum VoiceError: LocalizedError {
        case microphoneDenied
        case unsupportedLanguage
        case noAudioFormat

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
            case .unsupportedLanguage: "Speech-to-text isn't available for this language on this device."
            case .noAudioFormat: "No audio format is available for this speech model."
            }
        }
    }

    public private(set) var state: State = .idle
    /// Words that won't change any more.
    public private(set) var finalText = ""
    /// The latest guess at what's being said; it may still change.
    public private(set) var volatileText = ""
    /// Everything heard so far: final words, then the latest guess.
    public var text: String { finalText + volatileText }
    /// How loud the microphone is right now, from 0 (silence) to 1, about ten times a second.
    /// For a level meter while listening.
    public private(set) var level: Double = 0

    public var model: Model
    /// Names the speech model should expect, e.g. "Claude" or a place in your app.
    public var vocabulary: [String]
    public var locale: Locale
    /// Also writes the raw audio here, e.g. to compare models on the same recording.
    public var recordingURL: URL?

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var microphone: Microphone?
    @ObservationIgnored private var results: Task<String?, Never>?
    @ObservationIgnored private var started: ContinuousClock.Instant?
    @ObservationIgnored private var firstText: ContinuousClock.Instant?

    public init(model: Model = .speech, vocabulary: [String] = [], locale: Locale = .current, recordingURL: URL? = nil) {
        self.model = model
        self.vocabulary = vocabulary
        self.locale = locale
        self.recordingURL = recordingURL
    }

    /// Starts listening. `text` updates as the user speaks until ``stop()``.
    public func start() async throws {
        guard state == .idle else { return }
        state = .preparing
        finalText = ""
        volatileText = ""
        firstText = nil
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw VoiceError.microphoneDenied }
            let module = try await Self.module(model, locale: locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw VoiceError.noAudioFormat
            }
            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.setContext(Self.context(vocabulary))
            try await analyzer.prepareToAnalyze(in: format)
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let microphone = try Microphone(analyzerFormat: format, recordingURL: recordingURL, continuation: continuation) { [weak self] level in
                Task { @MainActor in
                    guard self?.state == .listening else { return }
                    self?.level = level
                }
            }
            listen(to: module)
            try microphone.start()
            try await analyzer.start(inputSequence: inputs)
            self.analyzer = analyzer
            self.microphone = microphone
            started = .now
            state = .listening
        } catch {
            cancel()
            throw error
        }
    }

    /// Stops listening and returns the final transcript, once the last words have settled.
    @discardableResult
    public func stop() async -> Transcript {
        guard state == .listening, let analyzer, let microphone else {
            cancel()
            return Transcript(text: text, audioSeconds: 0, firstTextAfter: nil, finalAfterStop: 0)
        }
        state = .finishing
        let audioSeconds = microphone.stop()
        let stopped = ContinuousClock.now
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
        var firstTextAfter: Double?
        if let started, let firstText {
            firstTextAfter = started.duration(to: firstText).seconds
        }
        let transcript = Transcript(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            audioSeconds: audioSeconds,
            firstTextAfter: firstTextAfter,
            finalAfterStop: stopped.duration(to: .now).seconds
        )
        volatileText = ""
        reset()
        return transcript
    }

    /// Stops without waiting for the last words.
    public func cancel() {
        _ = microphone?.stop()
        results?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        volatileText = ""
        reset()
    }

    private func reset() {
        level = 0
        analyzer = nil
        microphone = nil
        results = nil
        started = nil
        state = .idle
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func listen(to module: any SpeechModule) {
        switch module {
        case let transcriber as SpeechTranscriber: listen(to: transcriber) { String($0.text.characters) }
        case let transcriber as DictationTranscriber: listen(to: transcriber) { String($0.text.characters) }
        default: break
        }
    }

    private func listen<Module: SpeechModule>(to module: Module, text: @escaping @Sendable (Module.Result) -> String) {
        results = Task { [weak self] in
            do {
                for try await result in module.results {
                    self?.receive(text(result), isFinal: result.isFinal)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        if firstText == nil, !text.isEmpty { firstText = .now }
        if isFinal {
            finalText += text
            volatileText = ""
        } else {
            volatileText = text
        }
    }

    // MARK: Files

    /// Transcribes a recording, e.g. one saved with `recordingURL`, to compare models on the same audio.
    public static func transcribe(
        audioFile url: URL,
        model: Model = .speech,
        vocabulary: [String] = [],
        locale: Locale = .current
    ) async throws -> Transcript {
        let file = try AVAudioFile(forReading: url)
        let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
        let module = try await module(model, locale: locale, live: false)
        let start = ContinuousClock.now
        let text: String
        switch module {
        case let transcriber as SpeechTranscriber:
            async let collected = collect(transcriber.results) { String($0.text.characters) }
            _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context(vocabulary), finishAfterFile: true)
            text = try await collected
        case let transcriber as DictationTranscriber:
            async let collected = collect(transcriber.results) { String($0.text.characters) }
            _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context(vocabulary), finishAfterFile: true)
            text = try await collected
        default:
            text = ""
        }
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), audioSeconds: audioSeconds,
                          firstTextAfter: nil, finalAfterStop: start.duration(to: .now).seconds)
    }

    private static func collect<Results: AsyncSequence & Sendable>(
        _ results: Results,
        text: @Sendable (Results.Element) -> String
    ) async throws -> String where Results.Element: SpeechModuleResult {
        var transcript = ""
        for try await result in results where result.isFinal {
            transcript += text(result)
        }
        return transcript
    }

    // MARK: Setup

    /// The transcriber for `model`, with its language model downloaded if needed.
    private static func module(_ model: Model, locale: Locale, live: Bool = true) async throws -> any SpeechModule {
        let module: any SpeechModule
        switch model {
        case .speech:
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw VoiceError.unsupportedLanguage }
            module = SpeechTranscriber(locale: supported, preset: live ? .progressiveTranscription : .transcription)
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { throw VoiceError.unsupportedLanguage }
            module = DictationTranscriber(locale: supported, preset: live ? .progressiveShortDictation : .shortDictation)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        return module
    }

    private static func context(_ vocabulary: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        if !vocabulary.isEmpty {
            context.contextualStrings[.general] = vocabulary
        }
        return context
    }
}

/// Microphone capture on the audio thread: streams buffers to the analyzer and, optionally,
/// writes them to a file. Not main-actor isolated, since its tap runs on the audio thread.
final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter: AnalyzerInputConverter
    private let file: AVAudioFile?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let sampleRate: Double
    private let onLevel: @Sendable (Double) -> Void
    private var frames: AVAudioFramePosition = 0

    init(
        analyzerFormat: AVAudioFormat,
        recordingURL: URL?,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Double) -> Void
    ) throws {
        self.onLevel = onLevel
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            file = try AVAudioFile(forWriting: recordingURL, settings: inputFormat.settings)
        } else {
            file = nil
        }
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        sampleRate = inputFormat.sampleRate
        self.continuation = continuation
    }

    func start() throws {
        let input = engine.inputNode
        try input.installAudioTap(onBus: 0, bufferSize: 4_096, format: input.outputFormat(forBus: 0)) { [self] buffer, time in
            receive(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
    }

    private func receive(_ buffer: AVReadOnlyAudioPCMBuffer, at time: AVAudioTime) {
        try? file?.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
        // The converter takes a mutable buffer; a copy of a few thousand frames is cheap.
        let copy = AVAudioPCMBuffer(copying: buffer)
        onLevel(Self.level(of: copy))
        for input in (try? converter.convert(copy, at: time)) ?? [] {
            continuation.yield(input)
        }
    }

    /// Loudness of the first channel, mapped from about -50 dB (silence) to -10 dB (loud
    /// speech) onto 0–1.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(Double(rms), 1e-7))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    /// Stops capture and ends the input stream. Returns the seconds of audio heard.
    func stop() -> Double {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        for input in (try? converter.flush()) ?? [] {
            continuation.yield(input)
        }
        continuation.finish()
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
