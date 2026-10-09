import RouterKit
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
                        ForEach(model.columns) { CompareCard(column: $0).frame(minWidth: 260) }
                    }
                    VStack(spacing: 12) {
                        ForEach(model.columns) { CompareCard(column: $0) }
                    }
                }
                .padding()
            }
            HStack(spacing: 8) {
                TextField("Prompt to compare", text: $model.prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        start()
                        return .handled
                    }
                Button(action: start) {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .disabled(!model.canRun)
                .accessibilityLabel("Compare")
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Compare routes")
        .task(id: runToken) {
            guard runToken != nil else { return }
            await model.run()
        }
    }

    private func start() {
        guard model.canRun else { return }
        runToken = UUID()
    }
}

private struct CompareCard: View {
    let column: CompareModel.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RouteLabel(column.route)
                    .font(.headline)
                if column.metrics?.isSimulated == true {
                    Text("simulated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if column.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if let note = column.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !column.content.isEmpty {
                Text(column.isRunning ? AttributedString(column.content.text) : MessageRow.markdown(column.content.text))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let metrics = column.metrics {
                Text("First token \(Format.seconds(metrics.timeToFirstToken)) · \(metrics.tokensPerSecond.map { String(format: "%.0f", $0) } ?? "—") tok/s · \(Format.cost(metrics.estimatedCost))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(column.route.tint.opacity(0.06), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
