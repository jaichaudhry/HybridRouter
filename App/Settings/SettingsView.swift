import ChatUI
import RouterKit
import SwiftUI

/// Route status and Claude credentials.
struct SettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Routes") {
                    ForEach(Route.allCases, id: \.self) { route in
                        RouteStatusRow(route: route, availability: model.availability(of: route))
                    }
                }

                Section {
                    LabeledContent("Claude", value: model.claudeAuth.mode.displayName)
                    if let failure = model.appAttestFailure {
                        Label("App Attest failed: \(failure)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if model.hasUserKey {
                        Button("Remove your key", role: .destructive) {
                            perform { try model.removeUserKey() }
                        }
                    } else {
                        SecureField("Anthropic API key", text: $keyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Save key") {
                            perform { try model.saveUserKey(keyDraft) }
                            keyDraft = ""
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Your key is stored in this device's Keychain and sent only to Anthropic.")
                }

                Section {
                    LabeledContent("Apple Cloud", value: model.isAppleCloudEnabled ? "Enabled in this build" : "Not enabled")
                } footer: {
                    Text("Apple Cloud needs Apple's Private Cloud Compute entitlement. See the README.")
                }

                Section("Developer") {
                    NavigationLink("Routing benchmark") {
                        RoutingBenchmarkView()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update the Keychain (\(error))."
        }
    }
}

private struct RouteStatusRow: View {
    let route: Route
    let availability: ProviderAvailability

    var body: some View {
        LabeledContent {
            switch availability {
            case .available:
                Text("Available")
            case .unavailable(let reason):
                Text(reason)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Label(route.displayName, systemImage: route.symbolName)
                .foregroundStyle(route.tint)
        }
        .accessibilityElement(children: .combine)
    }
}
