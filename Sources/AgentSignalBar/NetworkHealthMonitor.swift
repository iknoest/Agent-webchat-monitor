import Foundation
import Network

public final class NetworkHealthMonitor: @unchecked Sendable {
    public static let shared = NetworkHealthMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ava.AgentSignalBar.networkHealthMonitor")
    private let lock = NSLock()

    public private(set) var isConnected: Bool = true
    public private(set) var isStarted: Bool = false
    public var onConnectivityChange: ((Bool) -> Void)?

    private init() {}

    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = (path.status == .satisfied)
            self?.updateConnectivity(connected)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        lock.unlock()
        monitor.cancel()
    }

    public func updateConnectivity(_ connected: Bool) {
        lock.lock()
        let previous = isConnected
        isConnected = connected
        let changed = (previous != connected)
        lock.unlock()

        if changed {
            onConnectivityChange?(connected)
        }
    }

    public func setConnectedForTesting(_ connected: Bool) {
        updateConnectivity(connected)
    }
}
