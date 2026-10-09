import Synchronization

/// Remembers which turns were private and which route the next request runs on, so the
/// history transform can withhold private turns from Claude.
final class PrivacyLedger: Sendable {
    private struct State {
        var privatePromptIDs: Set<String> = []
        var route: Route = .onDevice
    }

    private let state = Mutex(State())

    var route: Route {
        get { state.withLock { $0.route } }
        set { state.withLock { $0.route = newValue } }
    }

    var privatePromptIDs: Set<String> {
        state.withLock { $0.privatePromptIDs }
    }

    func markPrivate(promptID: String) {
        state.withLock { _ = $0.privatePromptIDs.insert(promptID) }
    }
}
