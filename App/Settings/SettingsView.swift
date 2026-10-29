import AuthenticationServices
import ChatUI
import HybridRouterKit
import SwiftUI

/// Route status, the cloud model and its credentials.
struct SettingsView: View {
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var keyDraft = ""
    @State private var metaKeyDraft = ""
    @State private var openRouterKeyDraft = ""
    @State private var errorMessage: String?
    @State private var confirmsDeleteAll = false

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
                    LabeledContent("OpenRouter", value: model.hasUserOpenRouterKey ? "Your key" : (model.openRouterKey != nil ? "Dev key" : "Not set"))
                    NavigationLink {
                        OpenRouterModelPicker(app: model)
                    } label: {
                        LabeledContent("Model", value: model.openRouterModel.shortName)
                    }
                    if model.hasUserOpenRouterKey {
                        Button("Remove your key", role: .destructive) {
                            perform { try model.removeOpenRouterKey() }
                        }
                    } else {
                        Button {
                            Task { await signInWithOpenRouter() }
                        } label: {
                            if isSigningIn {
                                ProgressView()
                            } else {
                                Label("Sign in with OpenRouter", systemImage: "person.badge.key")
                            }
                        }
                        .disabled(isSigningIn)
                        if let signInError {
                            Text(signInError).font(.footnote).foregroundStyle(.red)
                        }
                        SecureField("Or paste an OpenRouter API key", text: $openRouterKeyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Save key") {
                            perform { try model.saveOpenRouterKey(openRouterKeyDraft) }
                            openRouterKeyDraft = ""
                        }
                        .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                    }
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Text("Hundreds of models, including Claude, GPT and Gemini, with your own OpenRouter account: replies are billed to your OpenRouter credits. Signing in creates a key on your account; you can cap its spending there and revoke it at openrouter.ai/keys. Your key is stored in this device's Keychain and sent only to OpenRouter. The router was tuned and benchmarked with Claude; other models work but haven't been benchmarked.")
                }

                Section {
                    LabeledContent("Apple Cloud", value: model.isAppleCloudEnabled
                        ? "Enabled in this build"
                        : (model.simulatesAppleCloud ? "Simulated on-device" : "Not enabled"))
                } footer: {
                    Text("Apple Cloud needs Apple's Private Cloud Compute entitlement. See the README.")
                }

                Section {
                    Toggle("Save chats", isOn: $model.savesChats)
                    Button("Delete all chats", role: .destructive) { confirmsDeleteAll = true }
                        .disabled(model.savedChats.isEmpty)
                        .confirmationDialog("Delete all saved chats?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                            Button("Delete all chats", role: .destructive) {
                                Task { await model.deleteAllChats() }
                            }
                        } message: {
                            Text("This can't be undone.")
                        }
                } header: {
                    Text("Chats")
                } footer: {
                    Text("Chats are saved only on this iPhone, encrypted while it's locked, and left out of backups. Private messages stay private after a chat is reopened.")
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
                    NavigationLink("Conversations") {
                        MultiTurnEvalView(app: model)
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

    /// OpenRouter's sign-in in a browser sheet, then the code is traded for a key on the
    /// person's account, saved to the Keychain like a pasted one.
    private func signInWithOpenRouter() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        let authorization = OpenRouterAuth.authorization(callbackURL: AppModel.openRouterCallbackURL,
                                                         keyLabel: "HybridRouter on \(UIDevice.current.name)")
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: authorization.url,
                callback: .customScheme(AppModel.openRouterCallbackScheme),
                additionalHeaderFields: [:]
            )
            let code = try OpenRouterAuth.code(from: callback, expectedState: authorization.state)
            let key = try await OpenRouterAuth.exchange(code: code, codeVerifier: authorization.codeVerifier)
            try model.saveOpenRouterKey(key)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            signInError = error.localizedDescription
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
