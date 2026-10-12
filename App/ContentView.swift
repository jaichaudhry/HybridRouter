import ChatUI
import HybridRouterKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var showsSummary = false
    @State private var showsCompare = false

    var body: some View {
        NavigationStack {
            ChatView(
                model: model.chat,
                samplePrompts: model.scenario.samplePrompts,
                samplePromptsFillDraft: model.scenario.samplePromptsFillDraft
            )
                .structuredContent(id: model.scenario.id) { content in
                    model.scenario.card(for: content)
                }
                .id(model.scenario.id)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ScenarioPicker(model: model)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Session summary", systemImage: "chart.pie") { showsSummary = true }
                            .disabled(model.chat.steps.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Compare routes", systemImage: "rectangle.split.3x1") { showsCompare = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.chat.prewarm() }
        }
        .sheet(isPresented: $showsCompare) {
            CompareSheet(app: model)
                .presentationSizing(.page)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showsSummary) {
            NavigationStack {
                SessionSummaryView(summary: model.chat.summary)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSummary = false }
                        }
                    }
            }
        }
    }
}

/// Switches between scenarios from the title bar. Each keeps its own conversation.
private struct ScenarioPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Scenario", selection: $model.selectedScenarioID) {
                ForEach(model.scenarios, id: \.id) { scenario in
                    Label(scenario.title, systemImage: scenario.symbolName).tag(scenario.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Label(model.scenario.title, systemImage: model.scenario.symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Scenario: \(model.scenario.title)")
    }
}

/// Compare mode: one prompt on every route, using the general chat's setup.
private struct CompareSheet: View {
    @State private var compare: CompareModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel) {
        let general = app.scenarios.first { $0.id == GeneralScenario().id } ?? app.scenarios[0]
        _compare = State(initialValue: CompareModel { app.makeFreshSession(for: general) })
    }

    var body: some View {
        NavigationStack {
            CompareView(model: compare)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
