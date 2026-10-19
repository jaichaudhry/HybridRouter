import HybridRouterKit
import HybridRouterKitVoice
import SwiftUI

/// Settings › Developer › Speech check: is Apple's on-device speech-to-text good enough for voice
/// input? Read each prompt aloud; the screen streams the transcript live, then compares it with
/// the typed prompt on words, speed, and whether it routes, stays private and gets the
/// exact-answer rule the same way. Saved audio can be re-run through the other Apple model.
struct SpeechCheckView: View {
    @State private var model: SpeechCheckModel

    init(app: AppModel) {
        _model = State(initialValue: SpeechCheckModel(app: app))
    }

    var body: some View {
        List {
            Section {
                Picker("Model", selection: $model.engine) {
                    ForEach(SpeechCheckModel.Engine.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isBusy)
                Toggle("Teach it our names", isOn: $model.usesVocabulary)
                    .disabled(model.isBusy)
            } footer: {
                Text("Tap a prompt, read it aloud, tap again to stop. Audio stays on this iPhone. \"Teach it our names\" adds Claude, Muse Wonder, Apple Cloud and the place names as contextual strings.")
            }

            if let summary = model.summary(for: model.engine) {
                Section("\(model.engine.title) so far") {
                    LabeledContent("Prompts", value: "\(summary.count)")
                    LabeledContent("Word error rate", value: summary.wordErrorRate.formatted(.percent.precision(.fractionLength(1))))
                    LabeledContent("Exact transcripts", value: "\(summary.exact) of \(summary.count)")
                    LabeledContent("Same route as typed", value: "\(summary.sameRoute) of \(summary.count)")
                    LabeledContent("Same privacy as typed", value: "\(summary.samePrivacy) of \(summary.count)")
                    LabeledContent("Same exact-answer rule", value: "\(summary.sameExact) of \(summary.count)")
                    if let firstText = summary.medianFirstText {
                        LabeledContent("First words on screen", value: Self.seconds(firstText))
                    }
                    if let finalAfterStop = summary.medianFinalAfterStop {
                        LabeledContent("Final text after Stop", value: Self.seconds(finalAfterStop))
                    }
                }
            }

            Section {
                ForEach(model.items) { item in
                    SpeechCheckRow(item: item, model: model)
                }
            } header: {
                Text("Prompts")
            }

            Section {
                Button("Run \(model.engine.other.title) on saved audio") {
                    Task { await model.rerunSavedAudio(with: model.engine.other) }
                }
                .disabled(model.isBusy || !model.hasAudio)
                if let file = model.exportFile {
                    ShareLink("Share results (JSON)", item: file)
                }
                ShareLink("Share summary (Markdown)", item: model.markdown)
            } footer: {
                Text("Re-running uses the exact audio you recorded, so the two models are compared fairly.")
            }

            if let status = model.status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Speech check")
        .onDisappear { model.cancel() }
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}

private struct SpeechCheckRow: View {
    let item: SpeechCheckModel.Item
    let model: SpeechCheckModel

    private var isRecording: Bool { model.recordingID == item.id }

    var body: some View {
        Button {
            Task { await model.toggleRecording(item.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle")
                        .foregroundStyle(isRecording ? .red : .accentColor)
                        .symbolEffect(.pulse, isActive: isRecording)
                    Text(item.text).font(.body.weight(.medium))
                }
                if isRecording, let voice = model.voice {
                    Text("\(voice.finalText)\(Text(voice.volatileText).foregroundStyle(.secondary))")
                        .font(.callout)
                }
                ForEach(SpeechCheckModel.Engine.allCases) { engine in
                    if let take = item.takes[engine] {
                        TakeSummary(engine: engine, take: take, showsEngine: item.takes.count > 1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy && !isRecording)
    }
}

private struct TakeSummary: View {
    let engine: SpeechCheckModel.Engine
    let take: SpeechCheckModel.Take
    let showsEngine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((showsEngine ? engine.shortTitle + ": " : "") + "“\(take.transcript)”")
                .font(.callout)
                .foregroundStyle(take.wordErrors == 0 ? Color.primary : Color.orange)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(take.mismatches, id: \.self) { mismatch in
                Label(mismatch, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var details: String {
        var parts = ["\(take.wordErrors) of \(take.referenceWords) words wrong"]
        if let firstText = take.firstTextAfter { parts.append("first words \(SpeechCheckView.seconds(firstText))") }
        if let final = take.finalAfterStop { parts.append("final \(SpeechCheckView.seconds(final)) after Stop") }
        parts.append("routes to \(take.spokenRoute)")
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class SpeechCheckModel {
    enum Engine: String, CaseIterable, Identifiable, Codable, CodingKeyRepresentable {
        case speechTranscriber
        case dictation

        var id: Self { self }
        var title: String {
            switch self {
            case .speechTranscriber: "SpeechTranscriber"
            case .dictation: "DictationTranscriber"
            }
        }
        var shortTitle: String {
            switch self {
            case .speechTranscriber: "Speech"
            case .dictation: "Dictation"
            }
        }
        var other: Engine { self == .speechTranscriber ? .dictation : .speechTranscriber }
        var voiceModel: VoiceInput.Model { self == .speechTranscriber ? .speech : .dictation }
    }

    /// One transcription of one prompt, compared with the typed prompt.
    struct Take: Codable, Equatable {
        var transcript: String
        var wordErrors: Int
        var referenceWords: Int
        /// Seconds from starting to the first transcribed text, when recorded live.
        var firstTextAfter: Double?
        /// Seconds from Stop to the final text, when recorded live.
        var finalAfterStop: Double?
        /// Seconds to transcribe the saved audio, when re-run from the file.
        var fileSeconds: Double?
        var audioSeconds: Double
        var typedRoute: String
        var spokenRoute: String
        var typedPrivacy: String?
        var spokenPrivacy: String?
        var typedExact: String?
        var spokenExact: String?
        var usedVocabulary: Bool

        var mismatches: [String] {
            var result: [String] = []
            if typedRoute != spokenRoute { result.append("Routes to \(spokenRoute), typed goes to \(typedRoute)") }
            if typedPrivacy != spokenPrivacy {
                result.append("Privacy: \(spokenPrivacy ?? "not private") when spoken, \(typedPrivacy ?? "not private") when typed")
            }
            if typedExact != spokenExact {
                result.append("Exact answer: \(spokenExact ?? "none") when spoken, \(typedExact ?? "none") when typed")
            }
            return result
        }
    }

    struct Item: Identifiable {
        let id: Int
        let text: String
        var audioURL: URL?
        var takes: [Engine: Take] = [:]
    }

    struct Summary {
        var count: Int
        var wordErrorRate: Double
        var exact: Int
        var sameRoute: Int
        var samePrivacy: Int
        var sameExact: Int
        var medianFirstText: Double?
        var medianFinalAfterStop: Double?
    }

    var engine: Engine = .speechTranscriber
    var usesVocabulary = true
    private(set) var items: [Item]
    private(set) var recordingID: Int?
    /// The voice input recording now, which the row reads for the live transcript.
    private(set) var voice: VoiceInput?
    private(set) var status: String?
    private(set) var isBusy = false
    private(set) var exportFile: URL?

    private let app: AppModel

    /// Prompts that stress speech-to-text where routing depends on it: letters and numbers for
    /// the exact-answer rule, model names, place names, spoken personal details for the privacy
    /// check, and short follow-ups.
    static let prompts = [
        "How many r's are in the word strawberry?",
        "What is 17 times 24?",
        "What day of the week is 45 days after a Friday?",
        "Convert 72 degrees Fahrenheit to Celsius.",
        "If I save 250 dollars a month, how much will I have after 18 months?",
        "Ask Claude to compare these two job offers.",
        "Can Muse Wonder explain how vaccines work?",
        "Use Apple Cloud to plan a weekend in Lisbon.",
        "Plan three days in Kyoto with a day trip to Nara.",
        "What's the best time of year to visit Reykjavik?",
        "Text my number, 415-555-0132, to Sam.",
        "My doctor prescribed a new medication for my blood pressure.",
        "Email the itinerary to jai@example.com.",
        "Rewrite this sentence so it sounds more friendly.",
        "Give me three ideas for a birthday dinner.",
        "Why is the sky blue?",
        "Summarize the pros and cons of electric cars.",
        "Why?",
        "Make it shorter.",
        "Write a Swift function that reverses a string.",
    ]

    static let vocabulary = ["Claude", "Muse Wonder", "Apple Cloud", "Kyoto", "Nara", "Lisbon", "Reykjavik", "Swift"]

    init(app: AppModel) {
        self.app = app
        items = Self.prompts.enumerated().map { Item(id: $0.offset + 1, text: $0.element) }
    }

    var hasAudio: Bool { items.contains { $0.audioURL != nil } }

    // MARK: Recording

    func toggleRecording(_ id: Int) async {
        if recordingID == id {
            await stop()
        } else if !isBusy {
            await start(id)
        }
    }

    private func start(_ id: Int) async {
        isBusy = true
        recordingID = id
        status = nil
        let audioURL = Self.audioDirectory.appending(path: "prompt-\(id).caf")
        let voice = VoiceInput(
            model: engine.voiceModel,
            vocabulary: usesVocabulary ? Self.vocabulary : [],
            recordingURL: audioURL
        )
        self.voice = voice
        do {
            try await voice.start()
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].audioURL = audioURL
            }
        } catch {
            status = "Couldn't start: \(error.localizedDescription)"
            self.voice = nil
            recordingID = nil
            isBusy = false
        }
    }

    private func stop() async {
        guard let voice, let id = recordingID else { return }
        let transcript = await voice.stop()
        self.voice = nil
        recordingID = nil
        await score(id, engine: engine, transcript: transcript.text, firstText: transcript.firstTextAfter,
                    finalAfterStop: transcript.finalAfterStop, fileSeconds: nil, audioSeconds: transcript.audioSeconds)
        isBusy = false
    }

    func cancel() {
        voice?.cancel()
        voice = nil
        recordingID = nil
        isBusy = false
    }

    /// Transcribes every saved recording with `engine`, from the audio files.
    func rerunSavedAudio(with engine: Engine) async {
        isBusy = true
        defer { isBusy = false }
        for item in items {
            guard let url = item.audioURL else { continue }
            status = "\(engine.title): prompt \(item.id)…"
            do {
                let result = try await VoiceInput.transcribe(audioFile: url, model: engine.voiceModel,
                                                             vocabulary: usesVocabulary ? Self.vocabulary : [])
                // For a file, the time "after stop" is the whole transcription.
                await score(item.id, engine: engine, transcript: result.text, firstText: nil,
                            finalAfterStop: nil, fileSeconds: result.finalAfterStop, audioSeconds: result.audioSeconds)
            } catch {
                status = "\(engine.title) failed on prompt \(item.id): \(error.localizedDescription)"
                return
            }
        }
        status = nil
    }

    // MARK: Scoring

    private func score(_ id: Int, engine: Engine, transcript: String, firstText: Double?,
                       finalAfterStop: Double?, fileSeconds: Double?, audioSeconds: Double) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let typed = items[index].text
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let score = TranscriptScore(reference: typed, transcript: spoken)
        let typedRouting = await route(typed)
        let spokenRouting = await route(spoken)
        items[index].takes[engine] = Take(
            transcript: spoken,
            wordErrors: score.wordErrors,
            referenceWords: score.referenceWords,
            firstTextAfter: firstText,
            finalAfterStop: finalAfterStop,
            fileSeconds: fileSeconds,
            audioSeconds: audioSeconds,
            typedRoute: typedRouting.route,
            spokenRoute: spokenRouting.route,
            typedPrivacy: typedRouting.privacy,
            spokenPrivacy: spokenRouting.privacy,
            typedExact: typedRouting.exact,
            spokenExact: spokenRouting.exact,
            usedVocabulary: usesVocabulary
        )
        writeExport()
    }

    /// Routes a prompt as if every route were available, so typed and spoken can be compared
    /// whatever keys this phone has. Runs the real on-device classifier; nothing is generated.
    private func route(_ prompt: String) async -> (route: String, privacy: String?, exact: String?) {
        let privacy = PrivacyGuard().assess(prompt)?.label
        let exact = ExactAnswerDetector.kind(of: prompt)
        let input = RoutingInput(
            privacyReason: privacy,
            availability: [.onDevice: .available, .appleCloud: .available, .cloud: .available],
            namedRoute: RouteMention.named(in: prompt),
            labels: app.routeLabels
        )
        let router = Router(classifier: OnDeviceClassifier(), detectsExactAnswers: true)
        let decision = await router.route(prompt, input: input).decision
        return (decision.map { app.routeLabels.name($0.route) } ?? "blocked", privacy, exact?.label)
    }

    func summary(for engine: Engine) -> Summary? {
        let takes = items.compactMap { $0.takes[engine] }
        guard !takes.isEmpty else { return nil }
        let words = takes.reduce(0) { $0 + $1.referenceWords }
        return Summary(
            count: takes.count,
            wordErrorRate: words == 0 ? 0 : Double(takes.reduce(0) { $0 + $1.wordErrors }) / Double(words),
            exact: takes.count(where: { $0.wordErrors == 0 }),
            sameRoute: takes.count(where: { $0.typedRoute == $0.spokenRoute }),
            samePrivacy: takes.count(where: { $0.typedPrivacy == $0.spokenPrivacy }),
            sameExact: takes.count(where: { $0.typedExact == $0.spokenExact }),
            medianFirstText: Self.median(takes.compactMap(\.firstTextAfter)),
            medianFinalAfterStop: Self.median(takes.compactMap(\.finalAfterStop))
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: Export

    var markdown: String {
        var lines = ["# Speech check", "", "On-device speech-to-text on \(UIDevice.current.model), \(Date.now.formatted(date: .abbreviated, time: .omitted)).", ""]
        for engine in Engine.allCases {
            guard let summary = summary(for: engine) else { continue }
            lines += [
                "## \(engine.title)", "",
                "| Prompts | Word error rate | Exact | Same route | Same privacy | Same exact-answer rule | First words | Final after Stop |",
                "|---|---|---|---|---|---|---|---|",
                "| \(summary.count) | \(String(format: "%.1f%%", summary.wordErrorRate * 100)) | \(summary.exact) | \(summary.sameRoute) | \(summary.samePrivacy) | \(summary.sameExact) | \(summary.medianFirstText.map(SpeechCheckView.seconds) ?? "–") | \(summary.medianFinalAfterStop.map(SpeechCheckView.seconds) ?? "–") |",
                "",
            ]
        }
        lines += ["## Transcripts", "", "| # | Typed | Model | Heard | Errors | Route typed → spoken |", "|---|---|---|---|---|---|"]
        for item in items {
            for engine in Engine.allCases {
                guard let take = item.takes[engine] else { continue }
                let cell = { (text: String) in text.replacingOccurrences(of: "|", with: "\\|") }
                lines.append("| \(item.id) | \(cell(item.text)) | \(engine.shortTitle) | \(cell(take.transcript)) | \(take.wordErrors) | \(take.typedRoute) → \(take.spokenRoute) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    private struct ExportItem: Codable {
        var id: Int
        var text: String
        var takes: [Engine: Take]
    }

    private func writeExport() {
        let export = items.filter { !$0.takes.isEmpty }.map { ExportItem(id: $0.id, text: $0.text, takes: $0.takes) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let name = "\(Date.now.formatted(.iso8601.year().month().day()))-speech-check.json"
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        guard let data = try? encoder.encode(export), (try? data.write(to: file)) != nil else { return }
        exportFile = file
    }

    static var audioDirectory: URL {
        let directory = URL.cachesDirectory.appending(path: "SpeechCheck")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
