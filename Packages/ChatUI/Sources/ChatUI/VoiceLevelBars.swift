import SwiftUI

/// Vertical bars that rise and fall with the microphone level while dictating, the usual sign
/// that a voice is being heard. With Reduce Motion, a still waveform.
struct VoiceLevelBars: View {
    /// Microphone loudness, 0–1.
    var level: Double
    var color: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Middle bars reach higher, like a voice waveform.
    private static let shape: [Double] = [0.55, 0.85, 1, 0.85, 0.55]

    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform")
                .foregroundStyle(color)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Self.shape.indices, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(width: 3, height: height(of: index, at: time))
                    }
                }
                .frame(height: 20)
                .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }

    /// At least a small dot even in silence; with sound, each bar wobbles out of step with its
    /// neighbours so the meter looks alive between level updates.
    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        // Quiet speech should still move the bars, so the level is lifted before scaling.
        let loudness = pow(min(max(level, 0), 1), 0.6)
        let wobble = 0.8 + 0.2 * sin(time * 9 + Double(index) * 1.3)
        let fraction = 0.15 + 0.85 * Self.shape[index] * loudness * wobble
        return max(3, 20 * fraction)
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach([0, 0.3, 0.6, 1], id: \.self) { level in
            VoiceLevelBars(level: level)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.red))
        }
    }
    .padding()
}
