import HybridRouterKit
import SwiftUI

/// One prompt, every route, side by side.
public struct CompareView: View {
    @Bindable var model: CompareModel
    /// Starting a run sets a new token; `.task(id:)` cancels the run if the view goes away.
    @State private var runToken: UUID?

    public init(model: CompareModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Side by side when there's room for three readable columns, stacked otherwise.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.columns) { card(for: $0).frame(minWidth: 260) }
                    }
                    VStack(spacing: 12) {
                        ForEach(model.columns) { card(for: $0) }
                    }
                }
                .padding()
                .animation(Motion.card, value: model.finishOrder)
            }
            .background(Theme.canvas)
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Prompt to compare", text: $model.prompt, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                        .onKeyPress(.return, phases: .down) { press in
                            guard !press.modifiers.contains(.shift) else { return .ignored }
                            start()
                            return .handled
                        }
                    Button(action: start) {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.labelOnFill)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(Theme.ink)
                    .disabled(!model.canRun)
                    .accessibilityLabel("Compare")
                }
            }
            .padding()
            .background(Theme.canvas)
        }
        .navigationTitle("Compare routes")
        .task(id: runToken) {
            guard runToken != nil else { return }
            await model.run()
        }
    }

    private func card(for column: CompareModel.Column) -> some View {
        CompareCard(column: column, isFirst: model.finishOrder.count > 1 && model.finishOrder.first == column.route)
    }

    private func start() {
        guard model.canRun else { return }
        runToken = UUID()
    }
}

private struct CompareCard: View {
    let column: CompareModel.Column
    /// Finished before the other routes.
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(column.route.displayName, systemImage: column.route.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(column.route.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .routeCapsule(column.route)
                if column.metrics?.isSimulated == true {
                    Text("simulated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if column.isRunning {
                    Image(systemName: column.route.symbolName)
                        .foregroundStyle(column.route.ink)
                        .symbolEffect(.breathe.pulse.byLayer, options: .repeating)
                        .accessibilityLabel("Answering")
                } else if isFirst {
                    Label("Finished first", systemImage: "flag.checkered")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(column.route.ink)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            if let note = column.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !column.content.isEmpty {
                StreamingText(text: MessageRow.markdown(column.content.text), isStreaming: column.isRunning)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let metrics = column.metrics {
                Text("First token \(Format.seconds(metrics.timeToFirstToken)) · \(metrics.tokensPerSecond.map { String(format: "%.0f", $0) } ?? "—") tok/s · \(Format.cost(metrics.estimatedCost))")
                    .font(.caption)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
