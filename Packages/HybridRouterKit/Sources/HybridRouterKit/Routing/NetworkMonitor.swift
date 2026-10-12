import Network
import Synchronization

/// Tracks whether the device is online, for the availability rule.
public final class NetworkMonitor: Sendable {
    private final class State: Sendable {
        let isOnline = Mutex(true)
    }

    private let monitor = NWPathMonitor()
    private let state = State()

    public init() {
        monitor.pathUpdateHandler = { [state] path in
            state.isOnline.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "dev.hybridrouter.network"))
    }

    deinit {
        monitor.cancel()
    }

    public var isOnline: Bool {
        state.isOnline.withLock { $0 }
    }
}
