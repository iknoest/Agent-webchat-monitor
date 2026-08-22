import Foundation
import AppKit

public enum AutoSwitchWatchState: Equatable, Sendable {
    case waitingForNextTurn
    case waitingForTerminal(boundTurnId: String?, armedAt: Date)
}

public struct OneShotSwitchTarget: Equatable, Sendable {
    public let provider: AgentID
    public let sessionId: String?
    public let targetTabId: Int?
    public let targetURL: String?
    public let armedAt: Date
    public var watchState: AutoSwitchWatchState

    public init(
        provider: AgentID,
        sessionId: String? = nil,
        targetTabId: Int? = nil,
        targetURL: String? = nil,
        armedAt: Date = Date(),
        watchState: AutoSwitchWatchState = .waitingForNextTurn
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.targetTabId = targetTabId
        self.targetURL = targetURL
        self.armedAt = armedAt
        self.watchState = watchState
    }

    public static func == (lhs: OneShotSwitchTarget, rhs: OneShotSwitchTarget) -> Bool {
        return lhs.provider == rhs.provider &&
            lhs.sessionId == rhs.sessionId &&
            lhs.targetTabId == rhs.targetTabId &&
            lhs.targetURL == rhs.targetURL &&
            lhs.watchState == rhs.watchState
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
        let now = Date()

        let initialStatus: AgentStatus
        let currentTurnId: String?

        if let sessId = sessionId {
            let session = AgentStore.shared.getSessions(for: provider).first(where: { $0.sessionId == sessId })
            initialStatus = session?.status ?? AgentStore.shared.getStatus(for: provider).status
            currentTurnId = session?.turnId ?? AgentStore.shared.getStatus(for: provider).turnId
        } else {
            let info = AgentStore.shared.getStatus(for: provider)
            initialStatus = info.status
            currentTurnId = info.turnId
        }

        let watchState: AutoSwitchWatchState
        if initialStatus == .working {
            // Already working: watch this active turn
            watchState = .waitingForTerminal(boundTurnId: currentTurnId, armedAt: now)
        } else {
            // Idle / Done / Blocked: wait for next new turn
            watchState = .waitingForNextTurn
        }

        armedTarget = OneShotSwitchTarget(
            provider: provider,
            sessionId: sessionId,
            targetTabId: targetTabId,
            targetURL: targetURL,
            armedAt: now,
            watchState: watchState
        )
        lock.unlock()

        print("🎯 Armed Turn-Aware One-Shot Switch for \(provider.displayName)\(sessionId != nil ? " (\(sessionId!))" : "") [state: \(watchState)]")
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
        newStatus: AgentStatus,
        turnId: String? = nil
    ) -> Bool {
        lock.lock()
        guard var current = armedTarget, current.provider == provider else {
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

        switch current.watchState {
        case .waitingForNextTurn:
            if newStatus == .working {
                // Next turn has started! Bind to it
                current.watchState = .waitingForTerminal(boundTurnId: turnId, armedAt: Date())
                armedTarget = current
                lock.unlock()
                print("🎯 Auto-Switch bound to new active turn for \(provider.displayName) (turnId: \(turnId ?? "active"))")
                return false
            } else if newStatus == .blocked {
                // Immediate Needs You (permission / prompt)
                let targetToFocus = current
                armedTarget = nil
                lock.unlock()
                executeTrigger(target: targetToFocus, fallbackSessionId: sessionId, fallbackTabId: targetTabId, fallbackURL: targetURL, status: newStatus)
                return true
            } else {
                // Idle or pre-existing Done arriving while waiting for next turn -> do NOT trigger!
                lock.unlock()
                return false
            }

        case .waitingForTerminal(let boundTurnId, let armedAt):
            if newStatus == .working {
                // Still in progress: update bound turn ID if previously nil
                if boundTurnId == nil && turnId != nil {
                    current.watchState = .waitingForTerminal(boundTurnId: turnId, armedAt: armedAt)
                    armedTarget = current
                }
                lock.unlock()
                return false
            }

            if newStatus == .done || newStatus == .blocked {
                // If boundTurnId was recorded, verify turn matching
                if let bound = boundTurnId, let incomingTurn = turnId, !incomingTurn.isEmpty {
                    if incomingTurn != bound {
                        // Mismatched / older child turn -> ignore!
                        lock.unlock()
                        return false
                    }
                }

                // Canonical terminal state reached for watched turn!
                let targetToFocus = current
                armedTarget = nil
                lock.unlock()
                executeTrigger(target: targetToFocus, fallbackSessionId: sessionId, fallbackTabId: targetTabId, fallbackURL: targetURL, status: newStatus)
                return true
            }

            lock.unlock()
            return false
        }
    }

    private func executeTrigger(
        target: OneShotSwitchTarget,
        fallbackSessionId: String?,
        fallbackTabId: Int?,
        fallbackURL: String?,
        status: AgentStatus
    ) {
        print("⚡ Triggering One-Shot Switch to \(target.provider.displayName) upon \(status.statusTitle)...")

        DispatchQueue.main.async { [weak self] in
            if let customHandler = self?.focusExecutionHandler {
                customHandler(
                    target.provider,
                    target.sessionId ?? fallbackSessionId,
                    target.targetTabId ?? fallbackTabId,
                    target.targetURL ?? fallbackURL
                )
            } else {
                if target.provider == .chatgpt, let url = target.targetURL ?? fallbackURL, !url.isEmpty {
                    WindowFocuser.focusAgent(.chatgpt, targetURL: url, tabId: target.targetTabId ?? fallbackTabId)
                } else {
                    WindowFocuser.focusAgent(
                        target.provider,
                        sessionId: target.sessionId ?? fallbackSessionId,
                        tabId: target.targetTabId ?? fallbackTabId
                    )
                }
            }
            self?.onArmedStateChanged?()
            MenuBarManager.shared.scheduleTitleAndMenuUpdate()
        }
    }

    public func resetTestMetrics() {
        lock.lock()
        armedTarget = nil
        lock.unlock()
        focusExecutionHandler = nil
        onArmedStateChanged = nil
    }
}
