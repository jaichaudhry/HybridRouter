import ChatUI
import FoundationModels
import Observation
import OSLog
import HybridRouterKit

/// App-wide state: configuration, Claude credentials, and one chat per scenario.
@MainActor
@Observable
final class AppModel {
    /// Chat first: it's the everyday mode, and its sample prompts still show all three routes.
    let scenarios: [any Scenario] = [GeneralScenario(), TripPlannerScenario(), DocumentHelperScenario()]
    /// Opens in Chat the first time, then wherever the user was last.
    var selectedScenarioID = AppModel.storedScenarioID {
        didSet {
            UserDefaults.standard.set(selectedScenarioID, forKey: Self.scenarioKey)
            chat.prewarm()
        }
    }

    private static let scenarioKey = "HRSelectedScenario"

    private static var storedScenarioID: String {
        UserDefaults.standard.string(forKey: scenarioKey) ?? GeneralScenario().id
    }

    private(set) var claudeAuth: ClaudeAuth
    /// Which model serves the cloud route. Switching keeps every conversation.
    var cloudModel: CloudModel = AppModel.storedCloudModel {
        didSet {
            UserDefaults.standard.set(cloudModel.rawValue, forKey: Self.cloudModelKey)
            rebuildSessions()
        }
    }
    /// Bumped when the Meta key changes, so views reading `hasMetaKey` refresh.
    private var metaKeyVersion = 0
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
        let cloud = Self.cloudProvider(Self.storedCloudModel, auth: auth, metaKey: Self.metaKey(config: config, secrets: secrets))
        var chats: [String: ChatModel] = [:]
        for scenario in scenarios {
            let session = Self.makeSession(
                scenario: scenario,
                config: config,
                cloud: cloud,
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
            cloud: currentCloudProvider,
            costTable: costTable,
            simulatesAppleCloud: simulatesAppleCloud,
            history: []
        )
    }

    /// A fresh session for the answer-quality benchmark, with the app's providers and the given
    /// Claude tier (`.deep` for the Opus column and the judge).
    /// Its cloud slot is Claude at `claudeTier` whatever the setting, or `cloud` if given.
    func makeBenchmarkSession(instructions: String, claudeTier: ClaudeProvider.Tier, cloud: (any ModelProvider)? = nil) -> RoutedSession {
        Self.makeSession(
            instructions: instructions,
            config: config,
            cloud: cloud ?? ClaudeProvider(auth: claudeAuth, tier: claudeTier),
            costTable: costTable,
            simulatesAppleCloud: simulatesAppleCloud
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
        let cloud = currentCloudProvider
        let simulates = simulatesAppleCloud
        for scenario in scenarios {
            chats[scenario.id]?.replaceSession { [config, costTable] history, privatePromptIDs in
                Self.makeSession(
                    scenario: scenario,
                    config: config,
                    cloud: cloud,
                    costTable: costTable,
                    simulatesAppleCloud: simulates,
                    history: history,
                    privatePromptIDs: privatePromptIDs
                )
            }
        }
    }

    // MARK: Cloud model

    private static let cloudModelKey = "HRCloudModel"
    static let metaAPIKeyAccount = "meta-api-key"

    private static var storedCloudModel: CloudModel {
        UserDefaults.standard.string(forKey: cloudModelKey).flatMap(CloudModel.init(rawValue:)) ?? .claude
    }

    /// Names for the UI, with the cloud route named for the model serving it.
    var routeLabels: RouteLabels { RouteLabels(cloud: cloudModel) }

    /// The user's Meta key from the Keychain, else the Debug-only developer key.
    var metaKey: String? {
        _ = metaKeyVersion
        return Self.metaKey(config: config, secrets: secrets)
    }

    /// Whether the user saved their own Meta key (not the developer one).
    var hasUserMetaKey: Bool {
        _ = metaKeyVersion
        return ((try? secrets.read(Self.metaAPIKeyAccount)) ?? nil) != nil
    }

    func saveMetaKey(_ key: String) throws {
        try secrets.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.metaAPIKeyAccount)
        metaKeyVersion += 1
        rebuildSessions()
    }

    func removeMetaKey() throws {
        try secrets.delete(Self.metaAPIKeyAccount)
        metaKeyVersion += 1
        rebuildSessions()
    }

    private var currentCloudProvider: any ModelProvider {
        Self.cloudProvider(cloudModel, auth: claudeAuth, metaKey: metaKey)
    }

    private static func metaKey(config: AppConfig, secrets: any SecretStore) -> String? {
        let userKey = (try? secrets.read(metaAPIKeyAccount)) ?? nil
        return userKey ?? config.allowedMetaDeveloperKey
    }

    private static func cloudProvider(_ model: CloudModel, auth: ClaudeAuth, metaKey: String?) -> any ModelProvider {
        switch model {
        case .claude: ClaudeProvider(auth: auth)
        case .museWonder: MuseProvider(apiKey: metaKey)
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
        cloud: any ModelProvider,
        costTable: CostTable,
        simulatesAppleCloud: Bool,
        history: [Transcript.Entry],
        privatePromptIDs: Set<String> = []
    ) -> RoutedSession {
        makeSession(
            instructions: scenario.instructions,
            tools: scenario.tools,
            appleOnlyTools: scenario.appleOnlyTools,
            config: config,
            cloud: cloud,
            costTable: costTable,
            simulatesAppleCloud: simulatesAppleCloud,
            history: history,
            privatePromptIDs: privatePromptIDs
        )
    }

    private static func makeSession(
        instructions: String,
        tools: [any Tool] = [],
        appleOnlyTools: [any Tool] = [],
        config: AppConfig,
        cloud: any ModelProvider,
        costTable: CostTable,
        simulatesAppleCloud: Bool,
        history: [Transcript.Entry] = [],
        privatePromptIDs: Set<String> = []
    ) -> RoutedSession {
        // The real entitlement always wins over the stand-in.
        let appleCloud: any ModelProvider = !config.isAppleCloudEnabled && simulatesAppleCloud
            ? SimulatedAppleCloudProvider()
            : AppleCloudProvider(isEnabled: config.isAppleCloudEnabled)
        return RoutedSession(
            instructions: instructions,
            tools: tools,
            appleOnlyTools: appleOnlyTools,
            onDevice: OnDeviceProvider(),
            appleCloud: appleCloud,
            claude: cloud,
            costTable: costTable,
            history: history,
            privatePromptIDs: privatePromptIDs
        )
    }
}
