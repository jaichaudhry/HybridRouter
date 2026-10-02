import ChatUI
import FoundationModels
import Observation
import OSLog
import RouterKit

/// App-wide state: configuration, Claude credentials, and the chat.
@MainActor
@Observable
final class AppModel {
    static let instructions = """
        You are a helpful assistant. Answer clearly and concisely. Use Markdown for lists and emphasis.
        """

    private(set) var claudeAuth: ClaudeAuth
    /// Why App Attest was abandoned this launch, if it was.
    private(set) var appAttestFailure: String?
    let chat: ChatModel

    @ObservationIgnored private let config: AppConfig
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let costTable: CostTable
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hybridrouter", category: "app")

    init(config: AppConfig = .load(), secrets: any SecretStore = KeychainStore(service: "dev.hybridrouter.HybridRouter")) {
        self.config = config
        self.secrets = secrets
        let costTable: CostTable
        do {
            costTable = try CostTable.bundled()
        } catch {
            // The price table ships in RouterKit's bundle; missing it is a packaging bug.
            preconditionFailure("prices.json is missing from RouterKit: \(error)")
        }
        self.costTable = costTable

        let auth = Self.resolveAuth(config: config, secrets: secrets, skipAppAttest: false)
        self.claudeAuth = auth
        let session = Self.makeSession(config: config, auth: auth, costTable: costTable, history: [])
        self.chat = ChatModel(session: session, costTable: costTable)
        prewarmClaude()
    }

    var isAppleCloudEnabled: Bool { config.isAppleCloudEnabled }

    var hasUserKey: Bool {
        ((try? secrets.read(KeychainStore.claudeAPIKeyAccount)) ?? nil) != nil
    }

    func availability(of route: Route) -> ProviderAvailability {
        chat.session.availability(of: route)
    }

    /// Saves the user's Claude key to the Keychain and switches the chat to it.
    func saveUserKey(_ key: String) throws {
        try secrets.write(key, for: KeychainStore.claudeAPIKeyAccount)
        reloadClaude()
    }

    func removeUserKey() throws {
        try secrets.delete(KeychainStore.claudeAPIKeyAccount)
        reloadClaude()
    }

    private func reloadClaude() {
        claudeAuth = Self.resolveAuth(config: config, secrets: secrets, skipAppAttest: appAttestFailure != nil)
        let auth = claudeAuth
        chat.replaceSession { [config, costTable] history in
            Self.makeSession(config: config, auth: auth, costTable: costTable, history: history)
        }
        logger.info("Claude auth is now \(auth.mode.displayName, privacy: .public)")
    }

    private func prewarmClaude() {
        guard case .appAttest = claudeAuth.mode else { return }
        let provider = ClaudeProvider(auth: claudeAuth)
        Task {
            do {
                try await provider.authenticateIfNeeded()
            } catch {
                // The error never contains credentials; it describes the attestation step that failed.
                logger.error("App Attest failed: \(error.localizedDescription, privacy: .public)")
                appAttestFailure = error.localizedDescription
                reloadClaude()
            }
        }
    }

    private static func resolveAuth(config: AppConfig, secrets: any SecretStore, skipAppAttest: Bool) -> ClaudeAuth {
        let userKey = (try? secrets.read(KeychainStore.claudeAPIKeyAccount)) ?? nil
        return ClaudeAuthSource.resolve(
            environment: config.claudeAuthEnvironment(skipAppAttest: skipAppAttest),
            userKey: userKey
        )
    }

    private static func makeSession(
        config: AppConfig,
        auth: ClaudeAuth,
        costTable: CostTable,
        history: [Transcript.Entry]
    ) -> RoutedSession {
        RoutedSession(
            instructions: instructions,
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: config.isAppleCloudEnabled),
            claude: ClaudeProvider(auth: auth),
            costTable: costTable,
            history: history
        )
    }
}
