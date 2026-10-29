import HybridRouterKit
import SwiftUI

/// Settings › OpenRouter › Model: a searchable list of OpenRouter's models, with each one's
/// context window, price and whether it can see images.
struct OpenRouterModelPicker: View {
    @Bindable var app: AppModel
    @State private var query = ""
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @Environment(\.dismiss) private var dismiss

    private var models: [OpenRouterModel] {
        let all = app.openRouterCatalog?.search(query) ?? []
        // Keep the current choice listed even before the catalog loads.
        if all.isEmpty, query.isEmpty { return [app.openRouterModel] }
        return all
    }

    var body: some View {
        List {
            if let refreshError {
                Label(refreshError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(models) { model in
                Button {
                    app.openRouterModel = model
                    dismiss()
                } label: {
                    OpenRouterModelRow(model: model, isSelected: model.id == app.openRouterModel.id)
                }
                .tint(.primary)
            }
        }
        .overlay {
            if isRefreshing, app.openRouterCatalog == nil {
                ProgressView("Loading models…")
            } else if models.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search models, e.g. gpt or gemini")
        .navigationTitle("OpenRouter model")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(isRefreshing)
        }
        .task {
            if app.openRouterCatalog == nil { await refresh() }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await app.refreshOpenRouterCatalog()
            refreshError = nil
        } catch {
            refreshError = "Couldn't load OpenRouter's models: \(error.localizedDescription)"
        }
    }
}

private struct OpenRouterModelRow: View {
    let model: OpenRouterModel
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.acceptsImages {
                Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("Sees images")
            }
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let context = model.contextLength >= 1_000_000
            ? "\(model.contextLength / 1_000_000)M"
            : "\(model.contextLength / 1_000)K"
        let price = model.price.input == 0 && model.price.output == 0
            ? "free"
            : String(format: "$%.2f in · $%.2f out per 1M tokens", model.price.input, model.price.output)
        return "\(context) context · \(price)"
    }
}
