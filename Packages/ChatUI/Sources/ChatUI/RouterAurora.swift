import HybridRouterKit
import SwiftUI

/// A slow mesh of the three route glows. Used behind the empty chat and the session summary.
/// Static with Reduce Motion, and plain canvas with Increase Contrast or Reduce Transparency.
public struct RouterAurora: View {
    /// How much of each route to show, e.g. a session's route mix. Equal when nil.
    let weights: [Route: Double]?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(weights: [Route: Double]? = nil) {
        self.weights = weights
    }

    public var body: some View {
        if contrast == .increased || reduceTransparency {
            Theme.canvas
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                MeshGradient(width: 3, height: 3, points: points(at: time), colors: colors)
            }
        }
    }

    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let drift = { (speed: Double, phase: Double) in Float(sin(time * speed + phase) * 0.12) }
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5 + drift(0.31, 0)], [0.5 + drift(0.23, 1), 0.5 + drift(0.27, 2)], [1, 0.5 + drift(0.19, 3)],
            [0, 1], [0.5, 1], [1, 1],
        ]
    }

    private var colors: [Color] {
        func glow(_ route: Route) -> Color {
            let share = weights.map { $0[route] ?? 0 } ?? (1 / 3)
            return route.glow.mix(with: Theme.canvas, by: 1 - (0.12 + 0.5 * share))
        }
        let canvas = Theme.canvas
        return [
            glow(.onDevice), canvas, glow(.appleCloud),
            canvas, canvas, canvas,
            canvas, glow(.cloud), canvas,
        ]
    }
}

/// The empty chat: what the app does, over the router aurora.
struct EmptyChatState: View {
    @Environment(\.routeLabels) private var labels
    var body: some View {
        ZStack {
            RouterAurora()
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Where should this run?")
                    .font(.title2.bold())
                    .fontWidth(.expanded)
                    .multilineTextAlignment(.center)
                Text("Auto picks a route for every turn. You'll always see which.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    ForEach(Route.allCases, id: \.self) { route in
                        Label(labels.name(route), systemImage: labels.symbol(route))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(route.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.card, in: .capsule)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 80)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}
