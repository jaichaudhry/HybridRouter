import ChatUI
import FoundationModels
import Observation
import OSLog
import RouterKit

/// App-wide state: configuration, Claude credentials, and one chat per scenario.
@MainActor
@Observable
final class AppModel {
    let scenarios: [any Scenario] = [TripPlannerScenario(), DocumentHelperScenario(), GeneralScenario()]
    var selectedScenarioID = TripPlannerScenario().id {
        didSet { chat.prewarm() }
    }

    private(set) var claudeAuth: ClaudeAuth
    /// Why App Attest was abandoned this launch, if it was.
    private(set) var appAttestFailure: String?
    /// Each scenario keeps its own conversation.
    private let chats: [String: ChatModel]

    @ObservationIgnored private let config: AppConfig
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let costTable: CostTable
    @ObservationIgnored private let logger = Logger(subsystem: "dev.hybridrouter", category: "app")
    @ObservationIgnored private let network = NetworkMonitor()

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
        let network = network
        var chats: [String: ChatModel] = [:]
        for scenario in scenarios {
            let session = Self.makeSession(scenario: scenario, config: config, auth: auth, costTable: costTable, history: [])
            let coordinator = TurnCoordinator(
                router: Router(classifier: OnDeviceClassifier(), mapping: scenario.mapping),
                estimator: OnDeviceTokenEstimator(),
                isOnline: { network.isOnline }
            )
            let chat = ChatModel(
                session: session,
                coordinator: coordinator,
                costTable: costTable,
                structuredOutputs: scenario.structuredOutputs
            )
            chat.imagesArePrivate = scenario.imagesArePrivate
            chats[scenario.id] = chat
        }
        self.chats = chats
        prewarmClaude()
    }

    var scenario: any Scenario {
        scenarios.first { $0.id == selectedScenarioID } ?? scenarios[0]
    }

    var chat: ChatModel {
        // Every scenario gets a chat in init.
        chats[scenario.id]!
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
        for scenario in scenarios {
            chats[scenario.id]?.replaceSession { [config, costTable] history, privatePromptIDs in
                Self.makeSession(
                    scenario: scenario,
                    config: config,
                    auth: auth,
                    costTable: costTable,
                    history: history,
                    privatePromptIDs: privatePromptIDs
                )
            }
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
        scenario: any Scenario,
        config: AppConfig,
        auth: ClaudeAuth,
        costTable: CostTable,
        history: [Transcript.Entry],
        privatePromptIDs: Set<String> = []
    ) -> RoutedSession {
        RoutedSession(
            instructions: scenario.instructions,
            tools: scenario.tools,
            appleOnlyTools: scenario.appleOnlyTools,
            onDevice: OnDeviceProvider(),
            appleCloud: AppleCloudProvider(isEnabled: config.isAppleCloudEnabled),
            claude: ClaudeProvider(auth: auth),
            costTable: costTable,
            history: history,
            privatePromptIDs: privatePromptIDs
        )
    }
}
