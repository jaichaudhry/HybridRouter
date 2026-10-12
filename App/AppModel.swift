import ChatUI
import FoundationModels
import Observation
import OSLog
import HybridRouterKit

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
            // The price table ships in HybridRouterKit's bundle; missing it is a packaging bug.
            preconditionFailure("prices.json is missing from HybridRouterKit: \(error)")
        }
        self.costTable = costTable

        let auth = Self.resolveAuth(config: config, secrets: secrets, skipAppAttest: false)
        self.claudeAuth = auth
        let network = network
        var chats: [String: ChatModel] = [:]
        for scenario in scenarios {
            let session = Self.makeSession(
                scenario: scenario,
                config: config,
                auth: auth,
                costTable: costTable,
                simulatesAppleCloud: Self.storedSimulatesAppleCloud,
                history: []
            )
            let chat = ChatModel(
                session: session,
                coordinator: Self.makeCoordinator(scenario: scenario, network: network),
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

    /// A fresh, empty session with the app's current providers, for measurements.
    func makeFreshSession(for scenario: any Scenario) -> RoutedSession {
        Self.makeSession(
            scenario: scenario,
            config: config,
            auth: claudeAuth,
            costTable: costTable,
            simulatesAppleCloud: simulatesAppleCloud,
            history: []
        )
    }

    func makeCoordinator(for scenario: any Scenario) -> TurnCoordinator {
        Self.makeCoordinator(scenario: scenario, network: network)
    }

    var prices: CostTable { costTable }

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
        rebuildSessions()
        let mode = claudeAuth.mode.displayName
        logger.info("Claude auth is now \(mode, privacy: .public)")
    }

    /// Rebuilds every scenario's session with the current providers, keeping each conversation
    /// and its private turns.
    private func rebuildSessions() {
        let auth = claudeAuth
        let simulates = simulatesAppleCloud
        for scenario in scenarios {
            chats[scenario.id]?.replaceSession { [config, costTable] history, privatePromptIDs in
                Self.makeSession(
                    scenario: scenario,
                    config: config,
                    auth: auth,
                    costTable: costTable,
                    simulatesAppleCloud: simulates,
                    history: history,
                    privatePromptIDs: privatePromptIDs
                )
            }
        }
    }

    // MARK: Simulated Apple Cloud (Debug builds only)

    private static let simulatesAppleCloudKey = "HRSimulateAppleCloud"

    private static var storedSimulatesAppleCloud: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: simulatesAppleCloudKey)
        #else
        false
        #endif
    }

    /// Serves Apple Cloud with the on-device model when the build lacks the real entitlement.
    /// Replies show "Apple Cloud (simulated)". Always off in Release builds.
    var simulatesAppleCloud: Bool = AppModel.storedSimulatesAppleCloud {
        didSet {
            #if DEBUG
            UserDefaults.standard.set(simulatesAppleCloud, forKey: Self.simulatesAppleCloudKey)
            rebuildSessions()
            #else
            simulatesAppleCloud = false
            #endif
        }
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

    private static func makeCoordinator(scenario: any Scenario, network: NetworkMonitor) -> TurnCoordinator {
        TurnCoordinator(
            router: Router(classifier: OnDeviceClassifier(), mapping: scenario.mapping),
            estimator: OnDeviceTokenEstimator(),
            isOnline: { network.isOnline }
        )
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
        simulatesAppleCloud: Bool,
        history: [Transcript.Entry],
        privatePromptIDs: Set<String> = []
    ) -> RoutedSession {
        // The real entitlement always wins over the stand-in.
        let appleCloud: any ModelProvider = !config.isAppleCloudEnabled && simulatesAppleCloud
            ? SimulatedAppleCloudProvider()
            : AppleCloudProvider(isEnabled: config.isAppleCloudEnabled)
        return RoutedSession(
            instructions: scenario.instructions,
            tools: scenario.tools,
            appleOnlyTools: scenario.appleOnlyTools,
            onDevice: OnDeviceProvider(),
            appleCloud: appleCloud,
            claude: ClaudeProvider(auth: auth),
            costTable: costTable,
            history: history,
            privatePromptIDs: privatePromptIDs
        )
    }
}
