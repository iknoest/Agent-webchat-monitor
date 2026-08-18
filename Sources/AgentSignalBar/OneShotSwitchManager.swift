import Foundation
import AppKit

public struct OneShotSwitchTarget: Equatable {
    public let provider: AgentID
    public let sessionId: String?
    public let targetTabId: Int?
    public let targetURL: String?
    public let armedAt: Date

    public init(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil,
        targetURL: String? = nil,
        armedAt: Date = Date()
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.targetTabId = targetTabId
        self.targetURL = targetURL
        self.armedAt = armedAt
    }

    public static func == (lhs: OneShotSwitchTarget, rhs: OneShotSwitchTarget) -> Bool {
        return lhs.provider == rhs.provider &&
            lhs.sessionId == rhs.sessionId &&
            lhs.targetTabId == rhs.targetTabId &&
            lhs.targetURL == rhs.targetURL
    }
}

public final class OneShotSwitchManager {
    public static let shared = OneShotSwitchManager()

    private let lock = NSLock()
    public private(set) var armedTarget: OneShotSwitchTarget?

    public var onArmedStateChanged: (() -> Void)?
    public var focusExecutionHandler: ((AgentID, String?, Int?, String?) -> Void)?

    private init() {}

    public func arm(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil,
        targetURL: String? = nil
    ) {
        lock.lock()
        armedTarget = OneShotSwitchTarget(
            provider: provider,
            sessionId: sessionId,
            targetTabId: targetTabId,
            targetURL: targetURL
        )
        lock.unlock()

        print("🎯 Armed One-Shot Switch for \(provider.displayName)\(sessionId != nil ? " (\(sessionId!))" : "")")
        onArmedStateChanged?()
        MenuBarManager.shared.scheduleTitleAndMenuUpdate()
    }

    public func disarm() {
        lock.lock()
        let wasArmed = armedTarget != nil
        armedTarget = nil
        lock.unlock()

        if wasArmed {
            print("🚫 Disarmed One-Shot Switch")
            onArmedStateChanged?()
            MenuBarManager.shared.scheduleTitleAndMenuUpdate()
        }
    }

    public func toggle(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil,
        targetURL: String? = nil
    ) {
        if isArmed(provider: provider, sessionId: sessionId, targetTabId: targetTabId) {
            disarm()
        } else {
            arm(provider: provider, sessionId: sessionId, targetTabId: targetTabId, targetURL: targetURL)
        }
    }

    public func isArmed(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let current = armedTarget, current.provider == provider else {
            return false
        }

        if let curSess = current.sessionId, let reqSess = sessionId, !curSess.isEmpty, !reqSess.isEmpty {
            return curSess == reqSess
        }

        if let curTab = current.targetTabId, let reqTab = targetTabId {
            return curTab == reqTab
        }

        return true
    }

    @discardableResult
    public func evaluateTransition(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil,
        targetURL: String? = nil,
        newStatus: AgentStatus
    ) -> Bool {
        // Only trigger upon Done (New Output Ready) or Blocked (Needs You)
        guard newStatus == .done || newStatus == .blocked else {
            return false
        }

        lock.lock()
        guard let current = armedTarget, current.provider == provider else {
            lock.unlock()
            return false
        }

        // Match session identity if specified
        if let armedSess = current.sessionId, let transSess = sessionId, !armedSess.isEmpty, !transSess.isEmpty {
            if armedSess != transSess {
                lock.unlock()
                return false
            }
        }

        // Match tab identity if specified
        if let armedTab = current.targetTabId, let transTab = targetTabId {
            if armedTab != transTab {
                lock.unlock()
                return false
            }
        }

        // Target matched! Automatically disarm to prevent repeated focus stealing
        let targetToFocus = current
        armedTarget = nil
        lock.unlock()

        print("⚡ Triggering One-Shot Switch to \(provider.displayName) upon \(newStatus.statusTitle)...")

        DispatchQueue.main.async { [weak self] in
            if let customHandler = self?.focusExecutionHandler {
                customHandler(
                    targetToFocus.provider,
                    targetToFocus.sessionId ?? sessionId,
                    targetToFocus.targetTabId ?? targetTabId,
                    targetToFocus.targetURL ?? targetURL
                )
            } else {
                if targetToFocus.provider == .chatgpt, let url = targetToFocus.targetURL ?? targetURL, !url.isEmpty {
                    WindowFocuser.focusAgent(.chatgpt, targetURL: url, tabId: targetToFocus.targetTabId ?? targetTabId)
                } else {
                    WindowFocuser.focusAgent(
                        targetToFocus.provider,
                        sessionId: targetToFocus.sessionId ?? sessionId,
                        tabId: targetToFocus.targetTabId ?? targetTabId
                    )
                }
            }
            self?.onArmedStateChanged?()
            MenuBarManager.shared.scheduleTitleAndMenuUpdate()
        }

        return true
    }

    public func resetTestMetrics() {
        lock.lock()
        armedTarget = nil
        lock.unlock()
        focusExecutionHandler = nil
        onArmedStateChanged = nil
    }
}
