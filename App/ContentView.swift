import ChatUI
import RouterKit
import SwiftUI

struct ContentView: View {
    let model: AppModel

    @State private var showsSettings = false
    @State private var showsSummary = false

    var body: some View {
        NavigationStack {
            ChatView(model: model.chat)
                .navigationTitle("HybridRouter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Session summary", systemImage: "chart.pie") { showsSummary = true }
                            .disabled(model.chat.steps.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    }
                }
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
