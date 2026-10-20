import ChatUI
import FoundationModels
import Observation
import OSLog
import UIKit
import HybridRouterKit

/// App-wide state: configuration, Claude credentials, and the open chat in each scenario.
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
    /// What Auto does when a chat is too long for the route it picks: use a larger model, or
    /// stay and answer from recent messages. A route picked in the composer always stays.
    var longChats: Router.TooLongPolicy = AppModel.storedLongChats {
        didSet {
            UserDefaults.standard.set(longChats == .trimHistory, forKey: Self.longChatsKey)
            for chat in chats.values {
                chat.coordinator.router.whenTooLong = longChats
            }
        }
    }

    private static let longChatsKey = "HRLongChatsStay"

    private static var storedLongChats: Router.TooLongPolicy {
        UserDefaults.standard.bool(forKey: longChatsKey) ? .trimHistory : .useLargerModel
    }

    /// Bumped when the Meta key changes, so views reading `hasMetaKey` refresh.
    private var metaKeyVersion = 0
    /// Why App Attest was abandoned this launch, if it was.
    private(set) var appAttestFailure: String?
    /// The open chat in each scenario. The app starts with new chats; saved ones open from the
    /// chat list. A chat is saved once it has a message.
    private(set) var chats: [String: ChatModel]
    /// Saved chats, newest first, for the chat list.
    private(set) var savedChats: [ChatStore.Summary] = []
    /// Save chats on this device. Off stops saving; it doesn't delete saved chats.
    var savesChats: Bool = UserDefaults.standard.object(forKey: AppModel.savesChatsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(savesChats, forKey: Self.savesChatsKey) }
    }

    private static let savesChatsKey = "HRSavesChats"

    /// Which saved chat each scenario's open chat is.
    @ObservationIgnored private var openChats: [String: (id: UUID, createdAt: Date)] = [:]
    @ObservationIgnored let chatStore = ChatStore()

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
            chats[scenario.id] = ChatModel(
                session: Self.makeSession(
                    scenario: scenario,
                    config: config,
                    cloud: cloud,
                    costTable: costTable,
                    simulatesAppleCloud: Self.storedSimulatesAppleCloud
                ),
                coordinator: Self.makeCoordinator(scenario: scenario, network: network, longChats: Self.storedLongChats),
                costTable: costTable,
                structuredOutputs: scenario.structuredOutputs
            )
        }
        self.chats = chats
        for scenario in scenarios {
            setUp(chats[scenario.id]!, in: scenario, id: UUID(), createdAt: .now)
        }
        prewarmClaude()
        Task { savedChats = await chatStore.list() }
        Task { [chatStore] in
            // Saves made while the phone was locked can't be written until it's unlocked.
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                await chatStore.retryPendingSaves()
            }
        }
    }

    // MARK: Saved chats

    /// Starts a new, empty chat in the current scenario.
    func newChat() {
        let chat = makeChat(for: scenario)
        chats[scenario.id] = chat
        setUp(chat, in: scenario, id: UUID(), createdAt: .now)
        chat.prewarm()
    }

    /// Opens a saved chat, switching to its scenario.
    func openChat(_ id: UUID) async {
        do {
            let saved = try await chatStore.load(id)
            guard let scenario = scenarios.first(where: { $0.id == saved.scenarioID }) else { return }
            let chat = try makeChat(for: scenario, restoring: saved)
            chats[scenario.id] = chat
            setUp(chat, in: scenario, id: saved.id, createdAt: saved.createdAt)
            selectedScenarioID = scenario.id
        } catch {
            logger.error("Couldn't open a saved chat: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a saved chat. If it's open, its scenario starts a new chat.
    func deleteChat(_ id: UUID) async {
        try? await chatStore.delete(id)
        savedChats = await chatStore.list()
        for scenario in scenarios where openChats[scenario.id]?.id == id {
            let chat = makeChat(for: scenario)
            chats[scenario.id] = chat
            setUp(chat, in: scenario, id: UUID(), createdAt: .now)
        }
    }

    /// Deletes every saved chat and starts each scenario afresh.
    func deleteAllChats() async {
        try? await chatStore.deleteAll()
        savedChats = []
        for scenario in scenarios {
            let chat = makeChat(for: scenario)
            chats[scenario.id] = chat
            setUp(chat, in: scenario, id: UUID(), createdAt: .now)
        }
    }

    var openChatID: UUID? { openChats[scenario.id]?.id }

    /// Scenario settings and autosave for a chat that's becoming the scenario's open one.
    private func setUp(_ chat: ChatModel, in scenario: any Scenario, id: UUID, createdAt: Date) {
        chat.imagesArePrivate = scenario.imagesArePrivate
        openChats[scenario.id] = (id, createdAt)
        let scenarioID = scenario.id
        chat.onTurnFinished = { [weak self, weak chat] in
            guard let self, let chat else { return }
            save(chat, scenarioID: scenarioID)
        }
    }

    private func save(_ chat: ChatModel, scenarioID: String) {
        guard savesChats, !chat.messages.isEmpty, let open = openChats[scenarioID] else { return }
        let saved = chat.savedChat(id: open.id, scenarioID: scenarioID, createdAt: open.createdAt)
        Task {
            do {
                try await chatStore.save(saved)
            } catch {
                logger.error("Couldn't save the chat: \(error.localizedDescription, privacy: .public)")
            }
            savedChats = await chatStore.list()
        }
    }

    /// A chat for `scenario` with the app's current models and settings, new or continuing a saved one.
    private func makeChat(for scenario: any Scenario, restoring saved: SavedChat? = nil) throws -> ChatModel {
        let makeSession: ChatModel.SessionFactory = { [config, costTable, currentCloudProvider, simulatesAppleCloud] conversation in
            Self.makeSession(
                scenario: scenario,
                config: config,
                cloud: currentCloudProvider,
                costTable: costTable,
                simulatesAppleCloud: simulatesAppleCloud,
                conversation: conversation
            )
        }
        let coordinator = Self.makeCoordinator(scenario: scenario, network: network, longChats: longChats)
        guard let saved else {
            return ChatModel(session: makeSession(.empty), coordinator: coordinator, costTable: costTable,
                             structuredOutputs: scenario.structuredOutputs)
        }
        return try ChatModel(restoring: saved, makeSession: makeSession, coordinator: coordinator,
                             costTable: costTable, structuredOutputs: scenario.structuredOutputs)
    }

    private func makeChat(for scenario: any Scenario) -> ChatModel {
        // Only restoring can throw.
        try! makeChat(for: scenario, restoring: nil)
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
            simulatesAppleCloud: simulatesAppleCloud
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
        Self.makeCoordinator(scenario: scenario, network: network, longChats: longChats)
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
            chats[scenario.id]?.replaceSession { [config, costTable] conversation in
                Self.makeSession(
                    scenario: scenario,
                    config: config,
                    cloud: cloud,
                    costTable: costTable,
                    simulatesAppleCloud: simulates,
                    conversation: conversation
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

    private static func makeCoordinator(
        scenario: any Scenario,
        network: NetworkMonitor,
        longChats: Router.TooLongPolicy
    ) -> TurnCoordinator {
        TurnCoordinator(
            // The exact-answer detector: +4 points on held-out prompts, +6 on the test set, for
            // 3-4% more cost (README › Routing improvements).
            router: Router(
                classifier: OnDeviceClassifier(),
                mapping: scenario.mapping,
                detectsExactAnswers: true,
                whenTooLong: longChats
            ),
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
        conversation: RestoredConversation = .empty
    ) -> RoutedSession {
        makeSession(
            instructions: scenario.instructions,
            tools: scenario.tools,
            appleOnlyTools: scenario.appleOnlyTools,
            config: config,
            cloud: cloud,
            costTable: costTable,
            simulatesAppleCloud: simulatesAppleCloud,
            conversation: conversation
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
        conversation: RestoredConversation = .empty
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
            cloud: cloud,
            costTable: costTable,
            history: conversation.history,
            privatePromptIDs: conversation.privatePromptIDs,
            lastRoute: conversation.lastRoute
        )
    }
}
