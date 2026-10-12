import SwiftUI

/// Reply text that "inks in": while it streams, each newly arrived chunk fades up from a slight
/// blur. Only the newest chunks animate; once a reply finishes it's plain `Text`.
struct StreamingText: View {
    let text: AttributedString
    let isStreaming: Bool

    @State private var chunks: [Chunk] = []
    @State private var lastCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Chunk: Equatable {
        /// Character offset where the chunk starts.
        let start: Int
        let born: TimeInterval
    }

    var body: some View {
        Group {
            if isStreaming, !chunks.isEmpty {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    composed
                        .textRenderer(InkInRenderer(now: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion))
                }
            } else {
                Text(text)
            }
        }
        .onChange(of: text) { _, new in
            let count = new.characters.count
            let now = Date.now.timeIntervalSinceReferenceDate
            if count < lastCount {
                // The reply started over, e.g. after an escalation.
                chunks = []
            } else if count > lastCount, isStreaming {
                chunks.removeAll { now - $0.born > InkInRenderer.duration }
                chunks.append(Chunk(start: lastCount, born: now))
            }
            lastCount = count
        }
    }

    /// The text with each still-settling chunk tagged with when it arrived.
    private var composed: Text {
        let count = text.characters.count
        let starts = chunks.map { min($0.start, count) }
        let firstFresh = starts.first ?? count
        var result = Text(slice(0, firstFresh))
        for (index, chunk) in chunks.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : count
            let piece = Text(slice(starts[index], end)).customAttribute(FreshChunk(born: chunk.born))
            result = Text("\(result)\(piece)")
        }
        return result
    }

    private func slice(_ start: Int, _ end: Int) -> AttributedString {
        guard start < end else { return AttributedString() }
        let lower = text.characters.index(text.startIndex, offsetBy: start)
        let upper = text.characters.index(text.startIndex, offsetBy: end)
        return AttributedString(text[lower..<upper])
    }
}

/// Marks text that arrived at `born` and is still settling.
struct FreshChunk: TextAttribute {
    let born: TimeInterval
}

/// Draws fresh chunks fading up from a 3pt blur and offset; everything else draws as usual.
/// With Reduce Motion, fresh chunks only fade.
struct InkInRenderer: TextRenderer {
    /// How long a chunk takes to settle.
    static let duration: TimeInterval = 0.32

    let now: TimeInterval
    let reduceMotion: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let fresh = run[FreshChunk.self] else {
                    context.draw(run)
                    continue
                }
                let progress = min(max((now - fresh.born) / Self.duration, 0), 1)
                guard progress < 1 else {
                    context.draw(run)
                    continue
                }
                let eased = 1 - pow(1 - progress, 3)
                var copy = context
                copy.opacity = eased
                if !reduceMotion {
                    copy.addFilter(.blur(radius: (1 - eased) * 3))
                    copy.translateBy(x: 0, y: (1 - eased) * 3)
                }
                copy.draw(run)
            }
        }
    }
}
