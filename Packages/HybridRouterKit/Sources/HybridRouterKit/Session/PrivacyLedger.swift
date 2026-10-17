import Synchronization

/// What the history transform needs for the next request: which turns were private, which route
/// it runs on, and any limit on the history for this turn. The transform records how much of the
/// history it kept.
final class PrivacyLedger: Sendable {
    private struct State {
        var privatePromptIDs: Set<String> = []
        var route: Route = .onDevice
        var turnLimit: HistoryPolicy.Limit?
        var seen: HistoryView?
    }

    /// How many earlier turns the last request saw, out of how many there were.
    struct HistoryView: Equatable {
        var seen: Int
        var total: Int
    }

    private let state: Mutex<State>

    init(privatePromptIDs: Set<String> = []) {
        state = Mutex(State(privatePromptIDs: privatePromptIDs))
    }

    var route: Route {
        get { state.withLock { $0.route } }
        set { state.withLock { $0.route = newValue } }
    }

    /// A limit for this turn only, e.g. when the chat is too long for its route.
    var turnLimit: HistoryPolicy.Limit? {
        get { state.withLock { $0.turnLimit } }
        set { state.withLock { $0.turnLimit = newValue } }
    }

    var seen: HistoryView? {
        get { state.withLock { $0.seen } }
        set { state.withLock { $0.seen = newValue } }
    }

    var privatePromptIDs: Set<String> {
        state.withLock { $0.privatePromptIDs }
    }

    func markPrivate(promptID: String) {
        state.withLock { _ = $0.privatePromptIDs.insert(promptID) }
    }
}
