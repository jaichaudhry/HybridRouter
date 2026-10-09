import RouterKit
import SwiftUI

/// One prompt, every route, side by side.
public struct CompareView: View {
    @Bindable var model: CompareModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(model: CompareModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.columns) { CompareCard(column: $0) }
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.columns) { CompareCard(column: $0) }
                    }
                    .padding()
                }
            }
            HStack(spacing: 8) {
                TextField("Prompt to compare", text: $model.prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                    .onSubmit { Task { await model.run() } }
                Button {
                    Task { await model.run() }
                } label: {
                    Image(systemName: "play.circle.fill").font(.title)
                }
                .disabled(!model.canRun)
                .accessibilityLabel("Compare")
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Compare routes")
    }
}

private struct CompareCard: View {
    let column: CompareModel.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(column.route.displayName, systemImage: column.route.symbolName)
                    .font(.headline)
                    .foregroundStyle(column.route.tint)
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
                Text(MessageRow.markdown(column.content.text))
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
