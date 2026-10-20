import ChatUI
import HybridRouterKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false
    @State private var showsSummary = false
    @State private var showsCompare = false
    @State private var showsChats = false
    @Namespace private var transitions

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
                        Button("Chats", systemImage: "clock.arrow.circlepath") { showsChats = true }
                    }
                    .matchedTransitionSource(id: "chats", in: transitions)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil") { model.newChat() }
                            .disabled(model.chat.messages.isEmpty || model.chat.isSending)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("More", systemImage: "ellipsis") {
                            Button("Session summary", systemImage: "chart.pie") { showsSummary = true }
                                .disabled(model.chat.steps.isEmpty)
                            Button("Compare routes", systemImage: "rectangle.split.3x1") { showsCompare = true }
                            Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        }
                    }
                }
                // Toolbars stay monochrome; route colors are for content.
                .tint(Theme.ink)
        }
        // The cloud route is named for the model serving it, in every view and sheet.
        .environment(\.routeLabels, model.routeLabels)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.chat.prewarm() }
        }
        .sheet(isPresented: $showsCompare) {
            CompareSheet(app: model)
                .presentationSizing(.page)
        }
        .sheet(isPresented: $showsChats) {
            ChatsSheet(model: model)
                .zoomTransition(from: "chats", in: transitions)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
                .environment(\.routeLabels, model.routeLabels)
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

/// Saved chats, newest first: open one, start a new one, or swipe to delete.
private struct ChatsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New chat", systemImage: "square.and.pencil") {
                        model.newChat()
                        dismiss()
                    }
                    .disabled(model.chat.messages.isEmpty)
                }
                if model.savedChats.isEmpty {
                    Text(model.savesChats ? "Chats you have are saved here, on this iPhone." : "Saving chats is off in Settings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.scenarios.filter { scenario in model.savedChats.contains { $0.scenarioID == scenario.id } }, id: \.id) { scenario in
                    Section(scenario.title) {
                        ForEach(model.savedChats.filter { $0.scenarioID == scenario.id }) { chat in
                            Button {
                                Task {
                                    await model.openChat(chat.id)
                                    dismiss()
                                }
                            } label: {
                                ChatRow(chat: chat, isOpen: chat.id == model.openChatID && scenario.id == model.scenario.id)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await model.deleteChat(chat.id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ChatRow: View {
    let chat: ChatStore.Summary
    let isOpen: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .lineLimit(1)
                Text("\(chat.updatedAt.formatted(.relative(presentation: .named))) · \(chat.messageCount) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isOpen {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Open")
            }
        }
        .contentShape(.rect)
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

private extension View {
    /// Sheets zoom out of the toolbar button that opened them. With Reduce Motion they use
    /// the standard presentation.
    func zoomTransition(from sourceID: String, in namespace: Namespace.ID) -> some View {
        modifier(ZoomTransition(sourceID: sourceID, namespace: namespace))
    }
}

private struct ZoomTransition: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        }
    }
}
