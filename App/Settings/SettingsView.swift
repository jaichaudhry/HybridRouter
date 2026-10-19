import ChatUI
import HybridRouterKit
import SwiftUI

/// Route status, the cloud model and its credentials.
struct SettingsView: View {
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var metaKeyDraft = ""
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
                    Picker("Cloud model", selection: $model.cloudModel) {
                        ForEach(CloudModel.allCases, id: \.self) { cloud in
                            Label(cloud.displayName, systemImage: cloud.symbolName).tag(cloud)
                        }
                    }
                } footer: {
                    Text("The model behind the top route, for turns too big or hard for Apple's models. Private turns never reach it. Switching keeps your conversations.")
                }

                Section {
                    Picker("Long chats", selection: $model.longChats) {
                        Text("Use a larger model").tag(Router.TooLongPolicy.useLargerModel)
                        Text("Stay, with recent messages").tag(Router.TooLongPolicy.trimHistory)
                    }
                } footer: {
                    Text("On Auto, when a chat gets too long for the model the router picks: move to a larger model that sees the whole chat, or stay and answer from the most recent messages. A model you pick in the composer always stays. Private messages never reach the cloud model either way.")
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
                    LabeledContent("Muse Wonder", value: model.hasUserMetaKey ? "Your key" : (model.metaKey != nil ? "Dev key" : "Not set"))
                    if model.hasUserMetaKey {
                        Button("Remove your key", role: .destructive) {
                            perform { try model.removeMetaKey() }
                        }
                    } else {
                        SecureField("Meta Model API key", text: $metaKeyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Save key") {
                            perform { try model.saveMetaKey(metaKeyDraft) }
                            metaKeyDraft = ""
                        }
                        .disabled(metaKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Muse Wonder")
                } footer: {
                    Text("Meta's model, with your own key from dev.meta.ai. Replies are slower than Claude's: it reasons first and sends the whole reply at once, often 10 seconds or more. Your key is stored in this device's Keychain and sent only to Meta.")
                }

                Section {
                    LabeledContent("Apple Cloud", value: model.isAppleCloudEnabled
                        ? "Enabled in this build"
                        : (model.simulatesAppleCloud ? "Simulated on-device" : "Not enabled"))
                } footer: {
                    Text("Apple Cloud needs Apple's Private Cloud Compute entitlement. See the README.")
                }

                Section("Developer") {
                    NavigationLink("Routing benchmark") {
                        RoutingBenchmarkView()
                    }
                    NavigationLink("Measure routes") {
                        MeasureRoutesView(app: model)
                    }
                    NavigationLink("Answer quality") {
                        QualityEvalView(app: model)
                    }
                    NavigationLink("Speech check") {
                        SpeechCheckView(app: model)
                    }
                    NavigationLink("Apple Cloud checks") {
                        AppleCloudChecksView(app: model)
                    }
                    #if DEBUG
                    if !model.isAppleCloudEnabled {
                        Toggle("Simulate Apple Cloud", isOn: Binding(
                            get: { model.simulatesAppleCloud },
                            set: { model.simulatesAppleCloud = $0 }
                        ))
                    }
                    #endif
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
            RouteLabel(route)
        }
        .accessibilityElement(children: .combine)
    }
}
