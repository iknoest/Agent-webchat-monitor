import Foundation
import AppKit

public enum BadgeThemeMode: String, Codable, CaseIterable {
    case classic = "classic"
    case funEmoji = "funEmoji"

    public var displayName: String {
        switch self {
        case .classic: return "Classic Traffic Light"
        case .funEmoji: return "Emoji"
        }
    }
}

public enum AgentID: String, Codable, CaseIterable, Sendable {
    case chatgpt = "chatgpt"
    case codex = "codex"
    case claude = "claude"
    case antigravity = "antigravity"
    case copilot = "copilot"

    public var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT Web"
        case .codex: return "Codex Desktop"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .copilot: return "GitHub Copilot"
        }
    }

    public var symbol: String {
        switch self {
        case .chatgpt: return "💬"
        case .codex: return "💻"
        case .claude: return "🤖"
        case .antigravity: return "🚀"
        case .copilot: return "🐙"
        }
    }

    public var shortTag: String {
        switch self {
        case .chatgpt: return "GPT"
        case .codex: return "CDX"
        case .claude: return "CLD"
        case .antigravity: return "AGY"
        case .copilot: return "COP"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chatgpt: return "com.google.Chrome"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .antigravity: return "com.google.antigravity"
        case .copilot: return "com.github.githubapp"
        }
    }
}

public enum ProviderAvailability: String, Codable, Sendable {
    case available = "available"
    case limited = "limited"
    case quotaExhausted = "quotaExhausted"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .available: return "Available"
        case .limited: return "Limited"
        case .quotaExhausted: return "Quota Exhausted"
        case .unknown: return "Unknown"
        }
    }
}

public enum AgentStatus: String, Codable, Sendable {
    case off = "off"
    case idle = "idle"
    case working = "working"
    case done = "done"
    case blocked = "blocked"
    case quotaExceeded = "quotaExceeded"

    public func badge(theme: BadgeThemeMode = .classic, thinkingDuration: TimeInterval? = nil, overworkThresholdMinutes: Int = 10) -> String {
        let customBadges = ConfigManager.shared.config.statusBadges
        switch theme {
        case .classic:
            switch self {
            case .off: return customBadges.off.classic
            case .idle: return customBadges.idle.classic
            case .working: return customBadges.working.classic
            case .done: return customBadges.done.classic
            case .blocked: return customBadges.blocked.classic
            case .quotaExceeded: return customBadges.quotaDepleted?.classic ?? "⛔"
            }
        case .funEmoji:
            switch self {
            case .off: return customBadges.off.funEmoji
            case .idle: return customBadges.idle.funEmoji
            case .working:
                if let dur = thinkingDuration, dur >= Double(overworkThresholdMinutes * 60) {
                    return customBadges.overworking?.funEmoji ?? "🥵"
                }
                return customBadges.working.funEmoji
            case .done: return customBadges.done.funEmoji
            case .blocked: return customBadges.blocked.funEmoji
            case .quotaExceeded: return customBadges.quotaDepleted?.funEmoji ?? "🤯"
            }
        }
    }

    public func statusDot(theme: BadgeThemeMode = .classic) -> String {
        return badge(theme: theme)
    }

    public func statusDotImage() -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor
        switch self {
        case .off: color = NSColor.secondaryLabelColor
        case .idle: color = NSColor.labelColor.withAlphaComponent(0.4)
        case .working: color = NSColor.systemYellow
        case .done: color = NSColor.systemGreen
        case .blocked: color = NSColor.systemRed
        case .quotaExceeded: color = NSColor.systemOrange
        }

        let rect = NSRect(x: 1, y: 1, width: 10, height: 10)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    public var statusTitle: String {
        switch self {
        case .off: return "Closed"
        case .idle: return "Idle"
        case .working: return "Working..."
        case .done: return "NEW Output Ready!"
        case .blocked: return "ATTENTION NEEDED!"
        case .quotaExceeded: return "OUT OF QUOTA!"
        }
    }

    public var description: String {
        switch self {
        case .off: return "Not Running / Closed"
        case .idle: return "Idle (Inspected)"
        case .working: return "Working / Thinking..."
        case .done: return "NEW Output Ready (Unchecked)"
        case .blocked: return "Attention Needed / Waiting Approval"
        case .quotaExceeded: return "Out of Quota / Limit Exceeded"
        }
    }
}

public enum MonitorHealth: String, Codable, Sendable {
    case connected = "connected"
    case disconnected = "disconnected"
    case starting = "starting"
}

public enum EffectiveDisplayStatus: String, Codable, Sendable {
    case blocked = "blocked"
    case working = "working"
    case done = "done"
    case quotaRestored = "quotaRestored"
    case quotaExhausted = "quotaExhausted"
    case monitorUnavailable = "monitorUnavailable"
    case idle = "idle"
    case off = "off"

    public func badge(theme: BadgeThemeMode = .classic, thinkingDuration: TimeInterval? = nil, overworkThresholdMinutes: Int = 10) -> String {
        let customBadges = ConfigManager.shared.config.statusBadges
        switch theme {
        case .classic:
            switch self {
            case .off: return customBadges.off.classic
            case .idle: return customBadges.idle.classic
            case .quotaRestored: return customBadges.quotaRestored?.classic ?? customBadges.idle.classic
            case .working: return customBadges.working.classic
            case .done: return customBadges.done.classic
            case .blocked: return customBadges.blocked.classic
            case .quotaExhausted: return customBadges.quotaDepleted?.classic ?? "⛔"
            case .monitorUnavailable: return customBadges.monitorUnavailable?.classic ?? "⚠️"
            }
        case .funEmoji:
            switch self {
            case .off: return customBadges.off.funEmoji
            case .idle: return customBadges.idle.funEmoji
            case .quotaRestored: return customBadges.quotaRestored?.funEmoji ?? "🥱"
            case .working:
                if let dur = thinkingDuration, dur >= Double(overworkThresholdMinutes * 60) {
                    return customBadges.overworking?.funEmoji ?? "🥵"
                }
                return customBadges.working.funEmoji
            case .done: return customBadges.done.funEmoji
            case .blocked: return customBadges.blocked.funEmoji
            case .quotaExhausted: return customBadges.quotaDepleted?.funEmoji ?? "🤯"
            case .monitorUnavailable: return customBadges.monitorUnavailable?.funEmoji ?? "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}"
            }
        }
    }

    public func statusDotImage() -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()

        let color: NSColor
        switch self {
        case .off: color = NSColor.secondaryLabelColor
        case .idle, .quotaRestored: color = NSColor.labelColor.withAlphaComponent(0.4)
        case .working: color = NSColor.systemYellow
        case .done: color = NSColor.systemGreen
        case .blocked: color = NSColor.systemRed
        case .quotaExhausted: color = NSColor.systemOrange
        case .monitorUnavailable: color = NSColor.systemYellow
        }

        let rect = NSRect(x: 1, y: 1, width: 10, height: 10)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    public var statusTitle: String {
        switch self {
        case .off: return "Closed"
        case .idle: return "Idle"
        case .quotaRestored: return "Quota Restored"
        case .working: return "Working..."
        case .done: return "NEW Output Ready!"
        case .blocked: return "ATTENTION NEEDED!"
        case .quotaExhausted: return "Quota Exhausted"
        case .monitorUnavailable: return "Monitor Not Connected"
        }
    }

    public static func from(lifecycle: AgentStatus, availability: ProviderAvailability, isQuotaRestored: Bool = false) -> EffectiveDisplayStatus {
        switch lifecycle {
        case .blocked: return .blocked
        case .working: return .working
        case .done: return .done
        case .quotaExceeded: return .quotaExhausted
        case .idle:
            if availability == .quotaExhausted {
                return .quotaExhausted
            }
            if isQuotaRestored {
                return .quotaRestored
            }
            return .idle
        case .off: return .off
        }
    }

    public static func from(lifecycle: String, availability: ProviderAvailability, isQuotaRestored: Bool = false) -> EffectiveDisplayStatus {
        let status = AgentStatus(rawValue: lifecycle) ?? .idle
        return from(lifecycle: status, availability: availability, isQuotaRestored: isQuotaRestored)
    }
}

public struct ChatGPTTabInfo: Codable {
    public let tabId: Int?
    public let title: String
    public let url: String
    public var status: String
    public var badge: String?
    public let active: Bool?
    public var sensorReason: String?

    public init(tabId: Int? = nil, title: String, url: String, status: String, badge: String? = nil, active: Bool? = nil, sensorReason: String? = nil) {
        self.tabId = tabId
        self.title = title
        self.url = url
        self.status = status
        self.badge = badge
        self.active = active
        self.sensorReason = sensorReason
    }
}

public struct AgentSessionInfo: Codable, Sendable {
    public let provider: AgentID
    public let sessionId: String
    public var title: String
    public var status: AgentStatus
    public var turnId: String?
    public var attentionReason: String?
    public var thinkingStartTime: Date?
    public var lastDurationSeconds: TimeInterval?
    public var sourceEvidence: String
    public var lastUpdated: Date
    public var webLink: String?
    public var targetTabId: Int?
    public var acknowledgedTurnId: String?
    public var acknowledgedAt: Date?
    public var sensorReason: String?
    public var pendingToolName: String?
    public var pendingToolTime: Date?
    public var cwd: String?

    public var isAcknowledged: Bool {
        guard let ackId = acknowledgedTurnId, let tId = turnId, !ackId.isEmpty, !tId.isEmpty else {
            return false
        }
        return ackId == tId
    }

    public init(
        provider: AgentID,
        sessionId: String,
        title: String,
        status: AgentStatus,
        turnId: String? = nil,
        attentionReason: String? = nil,
        thinkingStartTime: Date? = nil,
        lastDurationSeconds: TimeInterval? = nil,
        sourceEvidence: String = "",
        lastUpdated: Date = Date(),
        webLink: String? = nil,
        targetTabId: Int? = nil,
        acknowledgedTurnId: String? = nil,
        acknowledgedAt: Date? = nil,
        sensorReason: String? = nil,
        pendingToolName: String? = nil,
        pendingToolTime: Date? = nil,
        cwd: String? = nil
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.title = title
        self.status = status
        self.turnId = turnId
        self.attentionReason = attentionReason
        self.thinkingStartTime = thinkingStartTime
        self.lastDurationSeconds = lastDurationSeconds
        self.sourceEvidence = sourceEvidence
        self.lastUpdated = lastUpdated
        self.webLink = webLink
        self.targetTabId = targetTabId
        self.acknowledgedTurnId = acknowledgedTurnId
        self.acknowledgedAt = acknowledgedAt
        self.sensorReason = sensorReason
        self.pendingToolName = pendingToolName
        self.pendingToolTime = pendingToolTime
        self.cwd = cwd
    }
}

public struct AgentInfo: Codable {
    public let id: AgentID
    public var status: AgentStatus
    public var availability: ProviderAvailability
    public var lastUpdated: Date
    public var detail: String?
    public var thinkingStartTime: Date?
    public var lastDurationSeconds: TimeInterval?
    public var tokenCount: Int?
    public var activeSessionCount: Int
    public var sessionTitle: String?
    public var targetTabId: Int?
    public var webLink: String?
    public var focusedStartTime: Date?
    public var openTabs: [ChatGPTTabInfo]
    public var revision: Int?
    public var turnId: String?
    public var isQuotaRestored: Bool
    public var monitorHealth: MonitorHealth

    public init(
        id: AgentID,
        status: AgentStatus = .off,
        availability: ProviderAvailability = .available,
        lastUpdated: Date = Date(),
        detail: String? = nil,
        thinkingStartTime: Date? = nil,
        lastDurationSeconds: TimeInterval? = nil,
        tokenCount: Int? = nil,
        activeSessionCount: Int = 1,
        sessionTitle: String? = nil,
        targetTabId: Int? = nil,
        webLink: String? = nil,
        focusedStartTime: Date? = nil,
        openTabs: [ChatGPTTabInfo] = [],
        revision: Int? = nil,
        turnId: String? = nil,
        isQuotaRestored: Bool = false,
        monitorHealth: MonitorHealth = .connected
    ) {
        self.id = id
        self.status = status
        self.availability = availability
        self.lastUpdated = lastUpdated
        self.detail = detail
        self.thinkingStartTime = thinkingStartTime
        self.lastDurationSeconds = lastDurationSeconds
        self.tokenCount = tokenCount
        self.activeSessionCount = activeSessionCount
        self.sessionTitle = sessionTitle
        self.targetTabId = targetTabId
        self.webLink = webLink
        self.focusedStartTime = focusedStartTime
        self.openTabs = openTabs
        self.revision = revision
        self.turnId = turnId
        self.isQuotaRestored = isQuotaRestored
        self.monitorHealth = monitorHealth
    }

    public var effectiveDisplayStatus: EffectiveDisplayStatus {
        if status == .off {
            return .off
        }
        if monitorHealth == .disconnected {
            return .monitorUnavailable
        }
        if status == .blocked {
            return .blocked
        }
        if status == .working {
            return .working
        }
        if status == .done {
            return .done
        }
        let effAvail = AgentUsageStore.shared.getUsage(for: id)?.availability ?? availability
        if effAvail == .quotaExhausted {
            return .quotaExhausted
        }
        if isQuotaRestored && status == .idle {
            return .quotaRestored
        }
        return .idle
    }
}

public final class AgentStore: @unchecked Sendable {
    public static let shared = AgentStore()

    private var states: [AgentID: AgentInfo] = [:]
    private var trackedSessions: [AgentID: [String: AgentSessionInfo]] = [:]
    private var stateObservers: [String: (AgentID, AgentStatus, AgentStatus, String?) -> Void] = [:]
    private let lock = NSLock()

    public var currentTheme: BadgeThemeMode = .classic
    public var overworkThresholdMinutes: Int = 10

    private var lastTopAgentID: AgentID? = nil
    private var lastTopStatus: AgentStatus? = nil
    private var lastTopTime: Date = .distantPast

    private var lastSeenAntigravityHookFingerprint: String = ""
    private var lastSeenAntigravityHookTime: Date = .distantPast

    private var lastChatGPTHeartbeat: Date? = nil
    private var appStartTime: Date = Date()
    public var startupGraceSeconds: TimeInterval = 60.0
    public var heartbeatLeaseSeconds: TimeInterval = 60.0

    public func recordChatGPTHeartbeat(date: Date = Date()) {
        lock.lock()
        lastChatGPTHeartbeat = date
        var info = states[.chatgpt] ?? AgentInfo(id: .chatgpt, status: .off)
        let oldHealth = info.monitorHealth
        info.monitorHealth = .connected
        states[.chatgpt] = info
        let changed = (oldHealth != .connected)
        lock.unlock()

        if changed {
            TelegramBridge.shared.handleChatGPTMonitorHealthChange(oldHealth: oldHealth, newHealth: .connected)
            MenuBarManager.shared.scheduleTitleAndMenuUpdate()
        }
    }

    public func checkChatGPTMonitorHealth(isChromeRunning: Bool, isMonitored: Bool, now: Date = Date()) -> MonitorHealth {
        lock.lock()
        defer { lock.unlock() }

        guard isMonitored else {
            return .connected
        }

        guard isChromeRunning else {
            return .connected
        }

        if let lastHb = lastChatGPTHeartbeat {
            let elapsed = now.timeIntervalSince(lastHb)
            if elapsed > heartbeatLeaseSeconds {
                return .disconnected
            } else {
                return .connected
            }
        } else {
            let elapsedSinceStart = now.timeIntervalSince(appStartTime)
            if elapsedSinceStart < startupGraceSeconds {
                return .starting
            } else {
                return .disconnected
            }
        }
    }

    public func setMonitorHealth(for agent: AgentID, health: MonitorHealth) {
        lock.lock()
        var info = states[agent] ?? AgentInfo(id: agent, status: .off)
        let oldHealth = info.monitorHealth
        info.monitorHealth = health
        states[agent] = info
        let changed = (oldHealth != health)
        lock.unlock()

        if changed {
            if agent == .chatgpt {
                TelegramBridge.shared.handleChatGPTMonitorHealthChange(oldHealth: oldHealth, newHealth: health)
            }
            MenuBarManager.shared.scheduleTitleAndMenuUpdate()
        }
    }

    public func setChatGPTMonitorHealth(_ health: MonitorHealth) {
        setMonitorHealth(for: .chatgpt, health: health)
    }

    public func setCodexMonitorHealth(_ health: MonitorHealth) {
        setMonitorHealth(for: .codex, health: health)
    }

    public func isMonitorDisconnected(for agent: AgentID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (states[agent]?.monitorHealth == .disconnected)
    }

    public func isChatGPTMonitorDisconnected() -> Bool {
        return isMonitorDisconnected(for: .chatgpt)
    }

    public func isCodexMonitorDisconnected() -> Bool {
        return isMonitorDisconnected(for: .codex)
    }

    public func resetChatGPTMonitorHealthForTesting(appStartTime: Date? = nil, lastHeartbeat: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let st = appStartTime {
            self.appStartTime = st
        } else {
            self.appStartTime = Date()
        }
        self.lastChatGPTHeartbeat = lastHeartbeat
        var info = states[.chatgpt] ?? AgentInfo(id: .chatgpt, status: .off)
        info.monitorHealth = (lastHeartbeat != nil) ? .connected : .starting
        states[.chatgpt] = info
    }

    public var onStateChanged: ((AgentID, AgentStatus, AgentStatus, String?) -> Void)? {
        get { nil }
        set {
            if let newValue = newValue {
                addObserver(id: "legacy", observer: newValue)
            }
        }
    }

    public func addObserver(id: String, observer: @escaping (AgentID, AgentStatus, AgentStatus, String?) -> Void) {
        lock.lock()
        stateObservers[id] = observer
        lock.unlock()
    }

    private func notifyObservers(agent: AgentID, oldStatus: AgentStatus, newStatus: AgentStatus, detail: String?) {
        lock.lock()
        let observers = Array(stateObservers.values)
        lock.unlock()
        for obs in observers {
            obs(agent, oldStatus, newStatus, detail)
        }
    }

    private init() {
        let savedThemeStr = ConfigManager.shared.config.badgeTheme ?? "classic"
        self.currentTheme = BadgeThemeMode(rawValue: savedThemeStr) ?? .classic
        self.overworkThresholdMinutes = ConfigManager.shared.config.overworkThresholdMinutes ?? 10

        for agent in AgentID.allCases {
            states[agent] = AgentInfo(id: agent, status: .off)
            trackedSessions[agent] = [:]
        }
    }

    public func setQuotaRestored(for agent: AgentID, restored: Bool) {
        lock.lock()
        var current = states[agent] ?? AgentInfo(id: agent)
        current.isQuotaRestored = restored
        states[agent] = current
        lock.unlock()
    }

    public func isQuotaRestored(for agent: AgentID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[agent]?.isQuotaRestored ?? false
    }

    public func clearQuotaRestored(for agent: AgentID) {
        setQuotaRestored(for: agent, restored: false)
    }

    public static func computeChatGPTAggregateStatus(openTabs: [ChatGPTTabInfo], defaultStatus: AgentStatus) -> AgentStatus {
        if openTabs.isEmpty { return defaultStatus }
        var hasBlocked = false
        var hasWorking = false
        var hasDone = false

        for tab in openTabs {
            let s = tab.status.lowercased()
            if s == "blocked" { hasBlocked = true }
            else if s == "working" { hasWorking = true }
            else if s == "done" { hasDone = true }
        }

        if hasBlocked { return .blocked }
        if hasWorking { return .working }
        if hasDone { return .done }
        return .idle
    }

    public func getSessions(for provider: AgentID) -> [AgentSessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array((trackedSessions[provider] ?? [:]).values)
    }

    public func getAllSessions() -> [AgentSessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        var result: [AgentSessionInfo] = []
        for dict in trackedSessions.values {
            result.append(contentsOf: dict.values)
        }
        return result
    }

    public func syncSessions(for provider: AgentID, activeSessions: [AgentSessionInfo], processRunning: Bool = true) {
        lock.lock()
        let currentDict = trackedSessions[provider] ?? [:]
        var updatedDict: [String: AgentSessionInfo] = [:]
        let now = Date()

        for var session in activeSessions {
            let key = session.sessionId
            if session.turnId == nil || session.turnId?.isEmpty == true {
                session.turnId = "\(session.sessionId)_turn_\(session.status.rawValue)"
            }

            if let existing = currentDict[key] {
                // Preserve acknowledgement if turn is unchanged and not working
                if session.status == .working {
                    session.acknowledgedTurnId = nil
                    session.acknowledgedAt = nil
                } else if let existingAck = existing.acknowledgedTurnId, let currentTurn = session.turnId, existingAck == currentTurn {
                    session.acknowledgedTurnId = existingAck
                    session.acknowledgedAt = existing.acknowledgedAt
                } else {
                    session.acknowledgedTurnId = nil
                    session.acknowledgedAt = nil
                }

                // Monotonic turn duration preservation
                if session.status == .working {
                    if let existingStart = existing.thinkingStartTime {
                        if session.turnId != nil && existing.turnId != nil && session.turnId != existing.turnId {
                            // Turn changed: use new session thinkingStartTime (or now if new turn started)
                            session.thinkingStartTime = session.thinkingStartTime ?? now
                        } else {
                            session.thinkingStartTime = existingStart
                        }
                    } else {
                        // Existing had no thinkingStartTime: keep session.thinkingStartTime as-is (nil if unknown)
                    }
                } else if existing.status == .working && (session.status == .done || session.status == .idle) {
                    if let start = existing.thinkingStartTime {
                        session.lastDurationSeconds = now.timeIntervalSince(start)
                    } else if let start = session.thinkingStartTime {
                        session.lastDurationSeconds = now.timeIntervalSince(start)
                    }
                    session.thinkingStartTime = nil
                }
            }
            updatedDict[key] = session
        }

        trackedSessions[provider] = updatedDict

        var currentParent = states[provider] ?? AgentInfo(id: provider)
        let oldStatus = currentParent.status

        if !processRunning {
            currentParent.status = .off
            currentParent.detail = "\(provider.displayName) closed"
            currentParent.activeSessionCount = 0
            currentParent.thinkingStartTime = nil
            states[provider] = currentParent
            lock.unlock()

            if oldStatus != .off {
                notifyObservers(agent: provider, oldStatus: oldStatus, newStatus: .off, detail: currentParent.detail)
            }
            return
        }

        let sessionList = Array(updatedDict.values)
        currentParent.activeSessionCount = max(1, sessionList.count)
        currentParent.lastUpdated = now

        var chosenSession: AgentSessionInfo? = nil
        if sessionList.isEmpty {
            currentParent.status = .idle
            if let d = currentParent.detail, d.contains("Monitoring unavailable") || d.contains("Experimental") {
                currentParent.detail = "Monitoring unavailable / Experimental"
            } else {
                currentParent.detail = "\(provider.displayName) running (0 tracked sessions)"
            }
            currentParent.thinkingStartTime = nil
        } else {
            let unackBlockedSessions = sessionList.filter { $0.status == .blocked && !$0.isAcknowledged }
            let workingSessions = sessionList.filter { $0.status == .working }
            let unackDoneSessions = sessionList.filter { $0.status == .done && !$0.isAcknowledged }

            if let topBlocked = unackBlockedSessions.first {
                currentParent.status = .blocked
                currentParent.detail = topBlocked.attentionReason ?? topBlocked.title
                chosenSession = topBlocked
            } else if let topWorking = workingSessions.first {
                currentParent.status = .working
                currentParent.isQuotaRestored = false
                var durationStr = ""
                let earliestStart = workingSessions.compactMap({ $0.thinkingStartTime }).min()
                currentParent.thinkingStartTime = earliestStart
                if let start = earliestStart {
                    let elapsed = Int(now.timeIntervalSince(start))
                    let mins = elapsed / 60
                    let secs = elapsed % 60
                    durationStr = mins > 0 ? " (thinking for \(mins)m \(secs)s)" : " (thinking for \(secs)s)"
                }
                currentParent.detail = "\(provider.displayName) active: \(topWorking.title)\(durationStr)"
                chosenSession = topWorking
            } else if let topDone = unackDoneSessions.first {
                currentParent.status = .done
                currentParent.detail = "\(provider.displayName) output ready: \(topDone.title)"
                currentParent.thinkingStartTime = nil
                if let dur = topDone.lastDurationSeconds {
                    currentParent.lastDurationSeconds = dur
                }
                chosenSession = topDone
            } else {
                currentParent.status = .idle
                currentParent.detail = "\(provider.displayName) ready (\(sessionList.count) tracked session(s))"
                currentParent.thinkingStartTime = nil
                chosenSession = sessionList.first
            }

            if let sel = chosenSession {
                currentParent.sessionTitle = sel.title
                currentParent.targetTabId = sel.targetTabId
                currentParent.webLink = sel.webLink
                currentParent.turnId = sel.turnId
                if !sel.sourceEvidence.isEmpty {
                    currentParent.detail = sel.sourceEvidence
                }
            }
        }

        states[provider] = currentParent
        let newStatus = currentParent.status
        let parentDetail = currentParent.detail
        lock.unlock()

        if oldStatus != newStatus {
            notifyObservers(agent: provider, oldStatus: oldStatus, newStatus: newStatus, detail: parentDetail)
            OneShotSwitchManager.shared.evaluateTransition(
                provider: provider,
                sessionId: chosenSession?.sessionId,
                targetTabId: chosenSession?.targetTabId,
                targetURL: chosenSession?.webLink,
                newStatus: newStatus,
                turnId: chosenSession?.turnId ?? currentParent.turnId
            )
        }
    }

    public func updateStatus(
        for agent: AgentID,
        status: AgentStatus,
        detail: String? = nil,
        tokenCount: Int? = nil,
        sessionCount: Int? = nil,
        sessionTitle: String? = nil,
        targetTabId: Int? = nil,
        webLink: String? = nil,
        openTabs: [ChatGPTTabInfo]? = nil,
        revision: Int? = nil,
        turnId: String? = nil
    ) {
        if agent == .chatgpt && openTabs != nil {
            let tabs = openTabs!
            var tabSessions: [AgentSessionInfo] = []
            for tab in tabs {
                let tabIdStr = tab.tabId != nil ? "\(tab.tabId!)" : tab.url
                let tabStatus = AgentStatus(rawValue: tab.status.lowercased()) ?? .idle
                let attReason = tabStatus == .blocked ? "🔴 Connection interrupted or page error" : nil
                let tabTurnId = turnId ?? "\(tabIdStr)_turn_\(tabStatus.rawValue)"
                let s = AgentSessionInfo(
                    provider: .chatgpt,
                    sessionId: tabIdStr,
                    title: tab.title,
                    status: tabStatus,
                    turnId: tabTurnId,
                    attentionReason: attReason,
                    thinkingStartTime: tabStatus == .working ? Date() : nil,
                    sourceEvidence: "ChatGPT Chrome tabRegistry",
                    lastUpdated: Date(),
                    webLink: tab.url,
                    targetTabId: tab.tabId,
                    sensorReason: tab.sensorReason
                )
                tabSessions.append(s)
            }
            syncSessions(for: .chatgpt, activeSessions: tabSessions, processRunning: status != .off)

            lock.lock()
            if var current = states[.chatgpt] {
                current.openTabs = tabs
                if let rev = revision { current.revision = rev }
                states[.chatgpt] = current
            }
            lock.unlock()
            return
        }

        let fallbackId = "session_\(agent.rawValue)"
        let titleStr = sessionTitle ?? agent.displayName
        let attReason = status == .blocked ? (detail ?? "Attention needed") : nil
        let sessionTurnId = turnId ?? "\(fallbackId)_turn_\(status.rawValue)"
        let session = AgentSessionInfo(
            provider: agent,
            sessionId: fallbackId,
            title: titleStr,
            status: status,
            turnId: sessionTurnId,
            attentionReason: attReason,
            thinkingStartTime: status == .working ? Date() : nil,
            sourceEvidence: detail ?? "Direct status update",
            lastUpdated: Date(),
            webLink: webLink,
            targetTabId: targetTabId
        )
        if status == .working {
            lock.lock()
            if var current = states[agent] {
                current.isQuotaRestored = false
                states[agent] = current
            }
            lock.unlock()
        }
        syncSessions(for: agent, activeSessions: [session], processRunning: status != .off)
    }

    public static func isSyntheticTestSessionId(_ sessionId: String) -> Bool {
        let lower = sessionId.lowercased()
        return lower.hasPrefix("test-") || lower.hasPrefix("test_") || lower.hasPrefix("mock_") ||
               lower == "session-alpha" || lower == "session-beta" || lower == "unknown_session"
    }

    public static func isUserFacingAntigravitySession(_ sessionId: String, isTestMode: Bool = false) -> Bool {
        let lower = sessionId.lowercased()
        if lower.contains("subagent") || lower.contains("worker") || lower.contains("research") {
            return false
        }

        if isTestMode || isSyntheticTestSessionId(sessionId) {
            return true
        }

        let annotationPath = NSString(string: "~/.gemini/antigravity/annotations/\(sessionId).pbtxt").expandingTildeInPath
        if FileManager.default.fileExists(atPath: annotationPath) {
            return true
        }

        let brainPath = NSString(string: "~/.gemini/antigravity/brain/\(sessionId)").expandingTildeInPath
        if FileManager.default.fileExists(atPath: brainPath) {
            // Brain exists but annotation file does not -> internal subagent / helper execution
            return false
        }

        // Neither exists yet (e.g. brand new conversation in flight before first write) -> allow initially
        return true
    }

    public func reconcileAntigravitySessions(isTestMode: Bool = false) {
        lock.lock()
        var currentSessions = trackedSessions[.antigravity] ?? [:]
        var changed = false

        for (sessionId, _) in currentSessions {
            if !AgentStore.isUserFacingAntigravitySession(sessionId, isTestMode: isTestMode) {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
            }
        }

        if changed {
            trackedSessions[.antigravity] = currentSessions
            lock.unlock()
            syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
        } else {
            lock.unlock()
        }
    }

    public func pruneStaleClaudeSessions(maxAgeSeconds: TimeInterval = 300) {
        lock.lock()
        var currentSessions = trackedSessions[.claude] ?? [:]
        let now = Date()
        var changed = false

        for (sessionId, session) in currentSessions {
            // MUST NEVER prune working or blocked sessions due to age!
            if session.status == .working || session.status == .blocked {
                continue
            }

            // Prune synthetic test sessions immediately if any exist
            if AgentStore.isSyntheticTestSessionId(sessionId) {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
                continue
            }

            // Prune ended sessions immediately upon SessionEnd
            if session.sensorReason?.contains("SessionEnd") == true || session.sourceEvidence.contains("SessionEnd") {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
                continue
            }

            // Prune completed (.done) or idle (.idle) sessions older than maxAgeSeconds (5 minutes)
            if now.timeIntervalSince(session.lastUpdated) > maxAgeSeconds {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
            }
        }

        if changed {
            trackedSessions[.claude] = currentSessions
        }
        lock.unlock()

        if changed {
            syncSessions(for: .claude, activeSessions: Array(currentSessions.values), processRunning: true)
        }
    }

    public func purgeSyntheticAndStaleSessions(provider: AgentID = .claude) {
        lock.lock()
        var currentDict = trackedSessions[provider] ?? [:]
        var changed = false
        for (key, session) in currentDict {
            if AgentStore.isSyntheticTestSessionId(key) {
                currentDict.removeValue(forKey: key)
                changed = true
            } else if session.status == .idle && (session.sensorReason?.contains("SessionEnd") == true || session.sourceEvidence.contains("SessionEnd")) {
                currentDict.removeValue(forKey: key)
                changed = true
            }
        }
        if changed {
            trackedSessions[provider] = currentDict
        }
        lock.unlock()

        if changed {
            syncSessions(for: provider, activeSessions: Array(currentDict.values), processRunning: true)
        }
    }

    public func handleClaudeHookEvent(json: [String: Any], isTestMode: Bool = false) -> Bool {
        guard let event = json["event"] as? String,
              let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            return false
        }

        // Test Isolation Guard: Reject synthetic test sessions in production monitor mode
        if !isTestMode && AgentStore.isSyntheticTestSessionId(sessionId) {
            print("⚠️ AgentStore ignored synthetic test session ID: \(sessionId)")
            return true
        }

        lock.lock()
        var currentSessions = trackedSessions[.claude] ?? [:]
        let rawCwd = json["cwd"] as? String ?? ""
        let folderName = (rawCwd as NSString).lastPathComponent
        let title = folderName.isEmpty ? "Claude Session (\(sessionId.prefix(8)))" : "[\(folderName)]"
        let toolName = json["tool_name"] as? String
        let promptId = json["prompt_id"] as? String
        let error = json["error"] as? String
        let now = Date()

        var session = currentSessions[sessionId] ?? AgentSessionInfo(
            provider: .claude,
            sessionId: sessionId,
            title: title,
            status: .idle,
            turnId: "turn_init_\(sessionId.prefix(8))",
            sourceEvidence: "Claude Hook: Registered",
            lastUpdated: now
        )

        session.title = title
        session.lastUpdated = now
        if !rawCwd.isEmpty {
            session.cwd = rawCwd
        }
        var eventTimestamp: Date? = nil
        if let tsStr = json["timestamp"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFormatter.date(from: tsStr) {
                eventTimestamp = d
            } else {
                let basicIso = ISO8601DateFormatter()
                if let d = basicIso.date(from: tsStr) {
                    eventTimestamp = d
                } else {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                    eventTimestamp = df.date(from: tsStr)
                }
            }
        } else if let tsNum = json["timestamp"] as? Double {
            if tsNum > 1_000_000_000_000 {
                eventTimestamp = Date(timeIntervalSince1970: tsNum / 1000.0)
            } else {
                eventTimestamp = Date(timeIntervalSince1970: tsNum)
            }
        }
        var shouldMarkQuotaExhausted = false

        switch event {
        case "SessionStart":
            if session.status == .off {
                session.status = .idle
            }
            session.sourceEvidence = "Claude Hook: SessionStart"
            session.sensorReason = "Claude Hook: SessionStart"

        case "UserPromptSubmit":
            let newTurnId = promptId != nil ? "turn_\(promptId!)" : "turn_submit_\(sessionId.prefix(8))_\(Int(now.timeIntervalSince1970 * 1000))"
            session.turnId = newTurnId
            session.status = .working
            session.thinkingStartTime = eventTimestamp ?? now
            session.attentionReason = nil
            session.acknowledgedTurnId = nil
            session.acknowledgedAt = nil
            session.sourceEvidence = "Claude Hook: UserPromptSubmit"
            session.sensorReason = "Claude Hook: UserPromptSubmit"

        case "PreToolUse", "PostToolUse":
            session.status = .working
            if session.thinkingStartTime == nil, let evTs = eventTimestamp {
                session.thinkingStartTime = evTs
            }
            let infoStr = toolName != nil ? "Claude Hook: Tool \(toolName!)" : "Claude Hook: \(event)"
            session.sourceEvidence = infoStr
            session.sensorReason = infoStr

        case "PermissionRequest":
            session.status = .blocked
            let reasonStr = toolName != nil ? "Permission required for \(toolName!)" : "Permission approval requested"
            session.attentionReason = reasonStr
            session.sourceEvidence = "Claude Hook: PermissionRequest"
            session.sensorReason = reasonStr
            let turnForNotification = session.turnId ?? "turn_perm_\(Int(now.timeIntervalSince1970 * 1000))"
            session.turnId = turnForNotification

        case "Stop":
            session.status = .done
            if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Claude Hook: Turn complete (Stop)"
            session.sensorReason = "Claude Hook: Turn complete (Stop)"

        case "StopFailure":
            let errStr = (error ?? "").lowercased()
            let isRateLimitOrQuota = errStr.contains("rate_limit") ||
                                     errStr.contains("rate limit") ||
                                     errStr.contains("quota") ||
                                     errStr.contains("429") ||
                                     errStr.contains("limit reached") ||
                                     errStr.contains("overloaded") ||
                                     errStr.contains("insufficient")

            if isRateLimitOrQuota {
                session.status = .idle
                session.attentionReason = nil
                session.sourceEvidence = "Claude Hook: Rate limit reached"
                session.sensorReason = "Rate limit reached: \(error ?? "rate_limit")"
                shouldMarkQuotaExhausted = true
            } else if session.status == .blocked {
                // Preserve genuine prior permission block
            } else {
                session.status = .idle
                session.attentionReason = nil
                let reasonStr = error != nil ? "Stop failed: \(error!)" : "Session stopped with failure"
                session.sourceEvidence = "Claude Hook: StopFailure (stopped)"
                session.sensorReason = reasonStr
            }
            if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil

        case "SessionEnd":
            session.status = .idle
            if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Claude Hook: SessionEnd"
            session.sensorReason = "Claude Hook: SessionEnd"
            // Immediate cleanup upon SessionEnd
            currentSessions.removeValue(forKey: sessionId)
            trackedSessions[.claude] = currentSessions
            lock.unlock()

            syncSessions(for: .claude, activeSessions: Array(currentSessions.values), processRunning: true)
            return true

        default:
            session.sourceEvidence = "Claude Hook: \(event)"
            session.sensorReason = "Claude Hook: \(event)"
        }

        currentSessions[sessionId] = session
        trackedSessions[.claude] = currentSessions
        lock.unlock()

        if shouldMarkQuotaExhausted {
            AgentUsageStore.shared.markQuotaExhausted(for: .claude)
        }

        syncSessions(for: .claude, activeSessions: Array(currentSessions.values), processRunning: true)
        return true
    }

    public func handleAntigravityHookEvent(json: [String: Any], isTestMode: Bool = false) -> Bool {
        guard let event = json["event"] as? String,
              let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            return false
        }

        // Test Isolation Guard: Reject synthetic test sessions in production monitor mode
        if !isTestMode && AgentStore.isSyntheticTestSessionId(sessionId) {
            print("⚠️ AgentStore ignored synthetic test session ID: \(sessionId)")
            return true
        }

        let toolName = json["tool_name"] as? String
        let stepIdx = json["step_idx"] as? Int ?? 0
        let invocationNum = json["invocation_num"] as? Int ?? 0
        let now = Date()

        lock.lock()

        // 1. Idempotency Guard: Deduplicate identical events arriving within 1s
        let fingerprint = "\(sessionId):\(event):\(toolName ?? ""):\(stepIdx):\(invocationNum)"
        if fingerprint == lastSeenAntigravityHookFingerprint && now.timeIntervalSince(lastSeenAntigravityHookTime) < 1.0 {
            lock.unlock()
            return true
        }
        lastSeenAntigravityHookFingerprint = fingerprint
        lastSeenAntigravityHookTime = now

        var currentSessions = trackedSessions[.antigravity] ?? [:]
        let rawCwd = json["cwd"] as? String ?? ""
        let folderName = (rawCwd as NSString).lastPathComponent
        let title = folderName.isEmpty ? "Antigravity (\(sessionId.prefix(8)))" : "[\(folderName)]"
        let error = json["error"] as? String ?? ((json["termination_reason"] as? String == "ERROR" || json["terminationReason"] as? String == "ERROR") ? "Error" : nil)
        let terminationReason = json["termination_reason"] as? String ?? json["terminationReason"] as? String

        // User-Facing Identity Guard: Filter out internal subagents / helper executions
        if !AgentStore.isUserFacingAntigravitySession(sessionId, isTestMode: isTestMode) {
            if currentSessions.removeValue(forKey: sessionId) != nil {
                trackedSessions[.antigravity] = currentSessions
                lock.unlock()
                syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
            } else {
                lock.unlock()
            }
            return true
        }

        var session = currentSessions[sessionId] ?? AgentSessionInfo(
            provider: .antigravity,
            sessionId: sessionId,
            title: title,
            status: .idle,
            turnId: nil,
            sourceEvidence: "Antigravity Hook: Registered",
            lastUpdated: now
        )

        session.title = title
        session.lastUpdated = now
        if !rawCwd.isEmpty {
            session.cwd = rawCwd
        }

        var eventTimestamp: Date? = nil
        if let tsStr = json["timestamp"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFormatter.date(from: tsStr) {
                eventTimestamp = d
            } else {
                let basicIso = ISO8601DateFormatter()
                if let d = basicIso.date(from: tsStr) {
                    eventTimestamp = d
                } else {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                    eventTimestamp = df.date(from: tsStr)
                }
            }
        } else if let tsNum = json["timestamp"] as? Double {
            if tsNum > 1_000_000_000_000 {
                eventTimestamp = Date(timeIntervalSince1970: tsNum / 1000.0)
            } else {
                eventTimestamp = Date(timeIntervalSince1970: tsNum)
            }
        }

        switch event {
        case "SessionStart":
            if session.status == .off {
                session.status = .idle
            }
            session.sourceEvidence = "Antigravity Hook: SessionStart"
            session.sensorReason = "Antigravity Hook: SessionStart"

        case "PreInvocation", "UserPromptSubmit":
            // 2. Logical turnId Continuity: Only generate fresh turnId and thinkingStartTime on first invocation of a new turn
            let isNewLogicalTurn = (session.status == .done || session.status == .idle || session.turnId == nil)
            if isNewLogicalTurn {
                let newTurnId = "turn_agy_\(sessionId.prefix(8))_\(Int(now.timeIntervalSince1970 * 1000))"
                session.turnId = newTurnId
                session.thinkingStartTime = eventTimestamp ?? now
            }
            session.status = .working
            session.attentionReason = nil
            session.acknowledgedTurnId = nil
            session.acknowledgedAt = nil
            session.sourceEvidence = "Antigravity Hook: PreInvocation"
            session.sensorReason = "Antigravity Hook: PreInvocation"

        case "PermissionRequested", "WaitingForInput", "WaitingForPermission", "UserConfirmation":
            session.status = .blocked
            let promptReason = json["reason"] as? String ?? json["prompt"] as? String ?? "Permission approval required"
            session.attentionReason = promptReason
            session.sourceEvidence = "Antigravity Hook: \(event) (\(toolName ?? "Permission"))"
            session.sensorReason = promptReason
            if session.turnId == nil {
                session.turnId = "turn_perm_\(Int(now.timeIntervalSince1970 * 1000))"
            }

        case "PermissionGranted", "PermissionResolved", "UserPromptResponse":
            session.status = .working
            session.attentionReason = nil
            session.sourceEvidence = "Antigravity Hook: \(event)"
            session.sensorReason = "Antigravity Hook: \(event)"

        case "PreToolUse":
            let isPermPrompt = (toolName == "ask_question" || json["is_permission_prompt"] as? Bool == true || json["requires_permission"] as? Bool == true || json["permission_required"] as? Bool == true)
            if isPermPrompt {
                session.status = .blocked
                let reasonStr = json["reason"] as? String ?? (toolName != nil ? "Permission / Question gate (\(toolName!))" : "User approval required")
                session.attentionReason = reasonStr
                session.sourceEvidence = "Antigravity Hook: PreToolUse (\(toolName ?? "Gate"))"
                session.sensorReason = reasonStr
                let turnForNotification = session.turnId ?? "turn_perm_\(Int(now.timeIntervalSince1970 * 1000))"
                session.turnId = turnForNotification
            } else {
                if session.status != .blocked {
                    session.status = .working
                }
                session.pendingToolName = toolName
                session.pendingToolTime = now
                if session.thinkingStartTime == nil, let evTs = eventTimestamp {
                    session.thinkingStartTime = evTs
                }
                let infoStr = toolName != nil ? "Antigravity Hook: Tool \(toolName!)" : "Antigravity Hook: PreToolUse"
                session.sourceEvidence = infoStr
                session.sensorReason = infoStr
            }

        case "PostToolUse":
            session.status = .working
            session.pendingToolName = nil
            session.pendingToolTime = nil
            session.attentionReason = nil
            if session.thinkingStartTime == nil, let evTs = eventTimestamp {
                session.thinkingStartTime = evTs
            }
            let infoStr = toolName != nil ? "Antigravity Hook: PostTool \(toolName!)" : "Antigravity Hook: PostToolUse"
            session.sourceEvidence = infoStr
            session.sensorReason = infoStr

        case "PostInvocation":
            // PostInvocation fires after tool steps inside a turn; remain Working to prevent Done flicker!
            if session.status != .blocked {
                session.status = .working
            }
            if session.thinkingStartTime == nil, let evTs = eventTimestamp {
                session.thinkingStartTime = evTs
            }
            session.sourceEvidence = "Antigravity Hook: PostInvocation"
            session.sensorReason = "Antigravity Hook: PostInvocation"

        case "Stop":
            let hasError = (error != nil && !error!.isEmpty) || terminationReason == "ERROR"

            if session.status == .blocked {
                // A. If already positively blocked by an actionable permission/question gate: preserve .blocked
                session.pendingToolName = nil
                session.pendingToolTime = nil
            } else if session.pendingToolName != nil {
                // B. Genuinely unresolved pending tool: preserve .working
                session.status = .working
            } else if hasError {
                // C. Non-actionable StopError / Stream Interruption / Quota Exhaustion / Error Stop
                // Transition to a NON-ACTIONABLE stopped/idle state (status = .idle)
                session.status = .idle
                session.attentionReason = nil
                session.pendingToolName = nil
                session.pendingToolTime = nil
                let errText = (error != nil && !error!.isEmpty) ? error! : "Stream interrupted / execution halted"
                let reasonStr = "Generation stopped: \(errText)"
                session.sourceEvidence = "Antigravity Hook: Generation stopped"
                session.sensorReason = reasonStr
                if let start = session.thinkingStartTime {
                    session.lastDurationSeconds = now.timeIntervalSince(start)
                }
                session.thinkingStartTime = nil
            } else {
                // D. Normal turn completion with zero errors -> .done (NEW Output Ready)
                session.status = .done
                session.attentionReason = nil
                session.sourceEvidence = "Antigravity Hook: Turn complete (Stop)"
                session.sensorReason = "Antigravity Hook: Turn complete (Stop)"
                session.pendingToolName = nil
                session.pendingToolTime = nil
                if let start = session.thinkingStartTime {
                    session.lastDurationSeconds = now.timeIntervalSince(start)
                }
                session.thinkingStartTime = nil
            }

        case "StopFailure":
            if session.status == .blocked {
                // Preserve .blocked if already positively blocked
            } else {
                session.status = .idle
                session.attentionReason = nil
                session.pendingToolName = nil
                session.pendingToolTime = nil
                let reasonStr = error != nil ? "Generation failed: \(error!)" : "Session stopped with error"
                session.sourceEvidence = "Antigravity Hook: Generation stopped"
                session.sensorReason = reasonStr
                if let start = session.thinkingStartTime {
                    session.lastDurationSeconds = now.timeIntervalSince(start)
                }
                session.thinkingStartTime = nil
            }

        case "SessionEnd":
            session.status = .idle
            if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Antigravity Hook: SessionEnd"
            session.sensorReason = "Antigravity Hook: SessionEnd"
            currentSessions.removeValue(forKey: sessionId)
            trackedSessions[.antigravity] = currentSessions
            lock.unlock()

            syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
            return true

        default:
            session.sourceEvidence = "Antigravity Hook: \(event)"
            session.sensorReason = "Antigravity Hook: \(event)"
        }

        currentSessions[sessionId] = session
        trackedSessions[.antigravity] = currentSessions
        lock.unlock()

        syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
        return true
    }

    // 2B. Codex Rollout Lifecycle Handler (Parent Rollout Event Truth)
    public func handleCodexTurnState(
        threadId: String,
        title: String? = nil,
        cwd: String? = nil,
        rolloutPath: String? = nil,
        status: AgentStatus,
        turnId: String?,
        thinkingStartTime: Date? = nil,
        durationMs: Double? = nil,
        isTestMode: Bool = false
    ) -> Bool {
        guard !threadId.isEmpty else { return false }
        if !isTestMode && AgentStore.isSyntheticTestSessionId(threadId) {
            return true
        }

        lock.lock()
        var currentSessions = trackedSessions[.codex] ?? [:]
        let rawCwd = cwd ?? ""
        let folderName = (rawCwd as NSString).lastPathComponent
        let defaultTitle = folderName.isEmpty ? "Codex (\(threadId.prefix(8)))" : "[\(folderName)]"
        let sessionTitle: String
        if let rawTitle = title, !rawTitle.isEmpty, AutoMonitor.isSafeSessionTitle(rawTitle) {
            sessionTitle = rawTitle
        } else if !folderName.isEmpty && AutoMonitor.isSafeSessionTitle(folderName) {
            sessionTitle = "[\(folderName)]"
        } else {
            sessionTitle = defaultTitle
        }
        let now = Date()

        var session = currentSessions[threadId] ?? AgentSessionInfo(
            provider: .codex,
            sessionId: threadId,
            title: sessionTitle,
            status: .idle,
            turnId: turnId,
            sourceEvidence: "Codex Turn State: Registered",
            lastUpdated: now
        )

        session.title = sessionTitle
        session.lastUpdated = now
        if !rawCwd.isEmpty {
            session.cwd = rawCwd
        }

        if status == .working {
            // Guard: If this exact session and turnId has already completed (.done) via rollout or history reconciliation,
            // do NOT regress back to .working unless a NEW turnId is provided!
            if session.status == .done, let curTurnId = session.turnId, let incomingTurnId = turnId, curTurnId == incomingTurnId {
                lock.unlock()
                return true
            }

            session.status = .working
            session.turnId = turnId
            session.thinkingStartTime = thinkingStartTime ?? session.thinkingStartTime
            session.attentionReason = nil
            session.acknowledgedTurnId = nil
            session.acknowledgedAt = nil
            session.sourceEvidence = "Codex Turn State: inProgress"
            session.sensorReason = "Codex Turn State: inProgress"
        } else if status == .done {
            session.status = .done
            session.turnId = turnId
            session.attentionReason = nil
            if let dMs = durationMs, dMs > 0 {
                session.lastDurationSeconds = dMs / 1000.0
            } else if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Codex Turn State: completed"
            session.sensorReason = "Codex Turn State: completed"
        } else if status == .idle {
            session.status = .idle
            session.thinkingStartTime = nil
            session.attentionReason = nil
            session.sourceEvidence = "Codex Turn State: idle"
            session.sensorReason = "Codex Turn State: idle"
        }

        currentSessions[threadId] = session
        trackedSessions[.codex] = currentSessions
        lock.unlock()

        syncSessions(for: .codex, activeSessions: Array(currentSessions.values), processRunning: true)
        return true
    }

    public func handleCodexRolloutEvent(
        threadId: String,
        title: String? = nil,
        cwd: String? = nil,
        rolloutPath: String? = nil,
        eventType: String,
        turnId: String?,
        durationMs: Double? = nil,
        isTestMode: Bool = false
    ) -> Bool {
        guard !threadId.isEmpty else { return false }

        // Test Isolation Guard: Reject synthetic test threads in production monitor mode
        if !isTestMode && AgentStore.isSyntheticTestSessionId(threadId) {
            return true
        }

        lock.lock()
        var currentSessions = trackedSessions[.codex] ?? [:]
        let rawCwd = cwd ?? ""
        let folderName = (rawCwd as NSString).lastPathComponent
        let defaultTitle = folderName.isEmpty ? "Codex (\(threadId.prefix(8)))" : "[\(folderName)]"
        let sessionTitle: String
        if let rawTitle = title, !rawTitle.isEmpty, AutoMonitor.isSafeSessionTitle(rawTitle) {
            sessionTitle = rawTitle
        } else if !folderName.isEmpty && AutoMonitor.isSafeSessionTitle(folderName) {
            sessionTitle = "[\(folderName)]"
        } else {
            sessionTitle = defaultTitle
        }
        let now = Date()

        var session = currentSessions[threadId] ?? AgentSessionInfo(
            provider: .codex,
            sessionId: threadId,
            title: sessionTitle,
            status: .idle,
            turnId: turnId,
            sourceEvidence: "Codex Rollout: Registered",
            lastUpdated: now
        )

        session.title = sessionTitle
        session.lastUpdated = now
        if !rawCwd.isEmpty {
            session.cwd = rawCwd
        }

        switch eventType {
        case "task_started":
            // Guard: If this exact session and turnId has already completed (.done) via rollout or history reconciliation,
            // do NOT regress back to .working unless a NEW turnId is provided!
            if session.status == .done, let curTurnId = session.turnId, let incomingTurnId = turnId, curTurnId == incomingTurnId {
                lock.unlock()
                return true
            }

            session.status = .working
            if let tId = turnId, !tId.isEmpty {
                session.turnId = tId
            }
            if session.thinkingStartTime == nil {
                session.thinkingStartTime = now
            }
            session.attentionReason = nil
            session.acknowledgedTurnId = nil
            session.acknowledgedAt = nil
            session.sourceEvidence = "Codex Rollout: Active"
            session.sensorReason = "Codex Rollout: Active"
            currentSessions[threadId] = session
            trackedSessions[.codex] = currentSessions
            lock.unlock()

            syncSessions(for: .codex, activeSessions: Array(currentSessions.values), processRunning: true)
            return true

        case "task_complete":
            // Turn-ID matching invariant: If both turn IDs are present, ensure they match
            if let incomingTurnId = turnId, let activeTurnId = session.turnId, !incomingTurnId.isEmpty, !activeTurnId.isEmpty {
                guard incomingTurnId == activeTurnId else {
                    lock.unlock()
                    return false
                }
            }

            session.status = .done
            session.attentionReason = nil
            if let dMs = durationMs, dMs > 0 {
                session.lastDurationSeconds = dMs / 1000.0
            } else if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Codex Rollout: Complete"
            session.sensorReason = "Codex Rollout: Complete"
            currentSessions[threadId] = session
            trackedSessions[.codex] = currentSessions
            lock.unlock()

            syncSessions(for: .codex, activeSessions: Array(currentSessions.values), processRunning: true)
            return true

        default:
            lock.unlock()
            return false
        }
    }

    public func reconcileCodexSessions(
        validThreadIds: Set<String>,
        historyTurns: [String: AutoMonitor.CodexHistoryTurnInfo]? = nil
    ) {
        lock.lock()
        var currentSessions = trackedSessions[.codex] ?? [:]
        var changed = false
        let now = Date()

        for (sessionId, session) in currentSessions {
            // 1. If session is a synthetic test session, ignore here (handled in unit tests)
            if AgentStore.isSyntheticTestSessionId(sessionId) {
                continue
            }

            // 2. If session is not among valid top-level threads (e.g. subagents, deleted, archived), remove it!
            if !validThreadIds.contains(sessionId) {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
                continue
            }

            // 3. If session is currently marked .working, verify with authoritative history turns
            if session.status == .working, let turns = historyTurns, let turnInfo = turns[sessionId] {
                if turnInfo.status == "completed" || turnInfo.completedAt != nil {
                    var updated = session
                    updated.status = .done
                    updated.turnId = turnInfo.turnId
                    updated.attentionReason = nil
                    if let dMs = turnInfo.durationMs, dMs > 0 {
                        updated.lastDurationSeconds = dMs / 1000.0
                    } else if let start = session.thinkingStartTime {
                        updated.lastDurationSeconds = now.timeIntervalSince(start)
                    }
                    updated.thinkingStartTime = nil
                    updated.sourceEvidence = "Codex History Reconciliation: completed"
                    updated.sensorReason = "Codex History Reconciliation: completed"
                    updated.lastUpdated = now
                    currentSessions[sessionId] = updated
                    changed = true
                } else if turnInfo.status == "failed" {
                    var updated = session
                    updated.status = .idle
                    updated.turnId = turnInfo.turnId
                    updated.attentionReason = nil
                    updated.thinkingStartTime = nil
                    updated.sourceEvidence = "Codex History Reconciliation: failed"
                    updated.sensorReason = "Codex History Reconciliation: failed"
                    updated.lastUpdated = now
                    currentSessions[sessionId] = updated
                    changed = true
                }
            }
        }

        if changed {
            trackedSessions[.codex] = currentSessions
        }
        lock.unlock()

        if changed {
            syncSessions(for: .codex, activeSessions: Array(currentSessions.values), processRunning: true)
        }
    }

    public func pruneStaleCodexSessions(maxAgeSeconds: TimeInterval = 300) {
        lock.lock()
        var currentSessions = trackedSessions[.codex] ?? [:]
        let now = Date()
        var changed = false

        for (sessionId, session) in currentSessions {
            // MUST NEVER prune working or blocked sessions due to age!
            if session.status == .working || session.status == .blocked {
                continue
            }

            // Prune synthetic test sessions immediately if any exist
            if AgentStore.isSyntheticTestSessionId(sessionId) {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
                continue
            }

            // Prune completed (.done) or idle (.idle) sessions older than maxAgeSeconds (5 minutes)
            if now.timeIntervalSince(session.lastUpdated) > maxAgeSeconds {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
            }
        }

        if changed {
            trackedSessions[.codex] = currentSessions
        }
        lock.unlock()

        if changed {
            syncSessions(for: .codex, activeSessions: Array(currentSessions.values), processRunning: true)
        }
    }

    public func handleCopilotEvent(
        sessionId: String,
        title: String,
        cwd: String = "",
        eventType: String,
        hookType: String? = nil,
        toolName: String? = nil,
        turnId: String? = nil,
        durationMs: Double? = nil
    ) -> Bool {
        guard !sessionId.isEmpty else { return false }

        lock.lock()
        var currentSessions = trackedSessions[.copilot] ?? [:]
        let now = Date()

        let folderName = (cwd as NSString).lastPathComponent
        let sessionTitle = title.isEmpty ? (folderName.isEmpty ? "Copilot Session (\(sessionId.prefix(8)))" : "[\(folderName)]") : title

        var session = currentSessions[sessionId] ?? AgentSessionInfo(
            provider: .copilot,
            sessionId: sessionId,
            title: sessionTitle,
            status: .idle,
            turnId: turnId ?? "turn_init_\(sessionId.prefix(8))",
            sourceEvidence: "Copilot Events: Registered",
            lastUpdated: now
        )

        session.title = sessionTitle
        session.lastUpdated = now
        if !cwd.isEmpty {
            session.cwd = cwd
        }

        let isStartHook = eventType == "hook.start" && (hookType == "userPromptSubmitted" || hookType == "UserPromptSubmit" || hookType == "SessionStart" || hookType == "SubagentStart")
        let isStopHook = (eventType == "hook.start" || eventType == "hook.end") && (hookType == "agentStop" || hookType == "Stop" || hookType == "SubagentStop")
        let isShutdownHook = (eventType == "hook.start" || eventType == "hook.end") && (hookType == "sessionEnd" || hookType == "SessionEnd")

        if eventType == "user.message" || eventType == "assistant.turn_start" || isStartHook {
            session.status = .working
            if let tid = turnId, !tid.isEmpty {
                session.turnId = tid
            }
            if session.thinkingStartTime == nil {
                session.thinkingStartTime = now
            }
            session.attentionReason = nil
            session.acknowledgedTurnId = nil
            session.acknowledgedAt = nil
            session.sourceEvidence = "Copilot Event: \(eventType)\(hookType != nil ? " (\(hookType!))" : "")"
            session.sensorReason = session.sourceEvidence
            currentSessions[sessionId] = session
            trackedSessions[.copilot] = currentSessions
            lock.unlock()

            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
            return true
        } else if eventType == "tool.execution_start" {
            if toolName == "ask_user" || toolName == "ask_question" || toolName == "permission_request" {
                session.status = .blocked
                let reasonStr = "Waiting for user response"
                session.attentionReason = reasonStr
                session.sensorReason = reasonStr
                session.sourceEvidence = "Copilot Tool: \(toolName ?? "ask_user")"
                if let tid = turnId, !tid.isEmpty {
                    session.turnId = tid
                }
            } else {
                session.status = .working
                if session.thinkingStartTime == nil {
                    session.thinkingStartTime = now
                }
                session.attentionReason = nil
                session.sourceEvidence = toolName != nil ? "Copilot Tool: \(toolName!)" : "Copilot Tool"
                session.sensorReason = session.sourceEvidence
            }
            currentSessions[sessionId] = session
            trackedSessions[.copilot] = currentSessions
            lock.unlock()

            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
            return true
        } else if eventType == "tool.execution_complete" {
            if session.status == .blocked && session.attentionReason == "Waiting for user response" {
                session.status = .working
                session.attentionReason = nil
                session.sourceEvidence = "Copilot Tool: ask_user completed"
                session.sensorReason = session.sourceEvidence
                currentSessions[sessionId] = session
                trackedSessions[.copilot] = currentSessions
                lock.unlock()

                syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
                return true
            }
            lock.unlock()
            return false
        } else if eventType == "assistant.turn_end" {
            session.status = .done
            session.attentionReason = nil
            if let dMs = durationMs, dMs > 0 {
                session.lastDurationSeconds = dMs / 1000.0
            } else if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Copilot Event: Turn complete (assistant.turn_end)"
            session.sensorReason = "Copilot Event: Turn complete (assistant.turn_end)"
            currentSessions[sessionId] = session
            trackedSessions[.copilot] = currentSessions
            lock.unlock()

            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
            return true
        } else if isStopHook {
            session.status = .idle
            session.attentionReason = nil
            if let start = session.thinkingStartTime {
                session.lastDurationSeconds = now.timeIntervalSince(start)
            }
            session.thinkingStartTime = nil
            session.sourceEvidence = "Copilot Event: Stopped / Cancelled (\(hookType ?? "agentStop"))"
            session.sensorReason = "Copilot Event: Stopped / Cancelled (\(hookType ?? "agentStop"))"
            currentSessions[sessionId] = session
            trackedSessions[.copilot] = currentSessions
            lock.unlock()

            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
            return true
        } else if eventType == "session.shutdown" || isShutdownHook {
            session.status = .idle
            session.attentionReason = nil
            session.thinkingStartTime = nil
            session.sourceEvidence = "Copilot Event: session.shutdown"
            session.sensorReason = "Copilot Event: session.shutdown"
            currentSessions[sessionId] = session
            trackedSessions[.copilot] = currentSessions
            lock.unlock()

            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
            return true
        } else {
            // Discard generic child tool/telemetry hooks without modifying state
            lock.unlock()
            return false
        }
    }

    public func pruneStaleCopilotSessions(maxAgeSeconds: TimeInterval = 300) {
        lock.lock()
        var currentSessions = trackedSessions[.copilot] ?? [:]
        let now = Date()
        var changed = false

        for (sessionId, session) in currentSessions {
            if session.status == .working || session.status == .blocked {
                continue
            }
            if AgentStore.isSyntheticTestSessionId(sessionId) {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
                continue
            }
            if now.timeIntervalSince(session.lastUpdated) > maxAgeSeconds {
                currentSessions.removeValue(forKey: sessionId)
                changed = true
            }
        }

        if changed {
            trackedSessions[.copilot] = currentSessions
        }
        lock.unlock()

        if changed {
            syncSessions(for: .copilot, activeSessions: Array(currentSessions.values), processRunning: true)
        }
    }

    // 3. Disambiguated Notification Center Correlation: Binds uniquely strongest candidate with unresolved native pending-tool evidence
    public func updateAntigravityPermissionFromNotification(reason: String) {
        lock.lock()
        var currentSessions = trackedSessions[.antigravity] ?? [:]
        let now = Date()
        let maxPendingToolAge: TimeInterval = 60.0 // Bounded safety lifetime for pending tool correlation

        let candidates = currentSessions.filter { (_, session) in
            guard let pTime = session.pendingToolTime else { return false }
            return now.timeIntervalSince(pTime) <= maxPendingToolAge && session.status != .blocked
        }

        if candidates.count == 1 {
            let targetId = candidates.keys.first!
            var session = currentSessions[targetId]!
            session.status = .blocked
            session.attentionReason = reason
            session.sensorReason = reason
            session.sourceEvidence = "macOS Notification Center: \(reason)"
            currentSessions[targetId] = session
            trackedSessions[.antigravity] = currentSessions
            lock.unlock()

            syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
        } else if candidates.count > 1 {
            let sorted = candidates.values.sorted { ($0.pendingToolTime ?? .distantPast) > ($1.pendingToolTime ?? .distantPast) }
            let t1 = sorted[0].pendingToolTime?.timeIntervalSince1970 ?? 0
            let t2 = sorted[1].pendingToolTime?.timeIntervalSince1970 ?? 0

            if (t1 - t2) > 3.0 {
                let mostRecentId = sorted[0].sessionId
                var session = currentSessions[mostRecentId]!
                session.status = .blocked
                session.attentionReason = reason
                session.sensorReason = reason
                session.sourceEvidence = "macOS Notification Center: \(reason)"
                currentSessions[mostRecentId] = session
                trackedSessions[.antigravity] = currentSessions
                lock.unlock()

                syncSessions(for: .antigravity, activeSessions: Array(currentSessions.values), processRunning: true)
            } else {
                // Ambiguous: multiple eligible candidates without clear timestamp separation.
                // Preserve ambiguity protection: do NOT arbitrarily assign to one child session.
                lock.unlock()
            }
        } else {
            // candidates.count == 0: NO unresolved native pending tool evidence.
            // Do NOT produce Needs You. Normal/non-permission notification is safely ignored.
            lock.unlock()
        }
    }

    public func markSessionChecked(provider: AgentID, sessionId: String, turnId: String? = nil) {
        lock.lock()
        if var current = states[provider] {
            current.isQuotaRestored = false
            states[provider] = current
        }
        var currentDict = trackedSessions[provider] ?? [:]
        guard var session = currentDict[sessionId] else {
            lock.unlock()
            return
        }

        let targetTurn = turnId ?? session.turnId ?? "turn_\(session.status.rawValue)"
        session.acknowledgedTurnId = targetTurn
        session.acknowledgedAt = Date()
        currentDict[sessionId] = session
        trackedSessions[provider] = currentDict
        lock.unlock()

        recalculateParentStatus(for: provider)
    }

    public func markChecked(for agent: AgentID) {
        lock.lock()
        if var current = states[agent] {
            current.isQuotaRestored = false
            states[agent] = current
        }
        var currentDict = trackedSessions[agent] ?? [:]
        let now = Date()
        for (key, var session) in currentDict {
            if session.status == .done || session.status == .blocked {
                let targetTurn = session.turnId ?? "turn_\(session.status.rawValue)"
                session.acknowledgedTurnId = targetTurn
                session.acknowledgedAt = now
                currentDict[key] = session
            }
        }
        trackedSessions[agent] = currentDict
        lock.unlock()

        recalculateParentStatus(for: agent)
    }

    private func recalculateParentStatus(for provider: AgentID) {
        lock.lock()
        let currentDict = trackedSessions[provider] ?? [:]
        let sessionList = Array(currentDict.values)
        var currentParent = states[provider] ?? AgentInfo(id: provider)
        let oldStatus = currentParent.status
        let now = Date()

        if sessionList.isEmpty {
            currentParent.status = .idle
            if let d = currentParent.detail, d.contains("Monitoring unavailable") || d.contains("Experimental") {
                currentParent.detail = "Monitoring unavailable / Experimental"
            } else {
                currentParent.detail = "\(provider.displayName) ready (0 tracked sessions)"
            }
        } else {
            let unackBlockedSessions = sessionList.filter { $0.status == .blocked && !$0.isAcknowledged }
            let workingSessions = sessionList.filter { $0.status == .working }
            let unackDoneSessions = sessionList.filter { $0.status == .done && !$0.isAcknowledged }

            let selectedSession: AgentSessionInfo?

            if let topBlocked = unackBlockedSessions.first {
                currentParent.status = .blocked
                currentParent.detail = topBlocked.attentionReason ?? topBlocked.title
                selectedSession = topBlocked
            } else if let topWorking = workingSessions.first {
                currentParent.status = .working
                let earliestStart = workingSessions.compactMap({ $0.thinkingStartTime }).min() ?? now
                currentParent.thinkingStartTime = earliestStart
                let elapsed = Int(now.timeIntervalSince(earliestStart))
                let mins = elapsed / 60
                let secs = elapsed % 60
                let durationStr = mins > 0 ? " (thinking for \(mins)m \(secs)s)" : " (thinking for \(secs)s)"
                currentParent.detail = "\(provider.displayName) active: \(topWorking.title)\(durationStr)"
                selectedSession = topWorking
            } else if let topDone = unackDoneSessions.first {
                currentParent.status = .done
                currentParent.detail = "\(provider.displayName) output ready: \(topDone.title)"
                currentParent.thinkingStartTime = nil
                if let dur = topDone.lastDurationSeconds {
                    currentParent.lastDurationSeconds = dur
                }
                selectedSession = topDone
            } else {
                currentParent.status = .idle
                currentParent.detail = "\(provider.displayName) ready (\(sessionList.count) tracked session(s))"
                currentParent.thinkingStartTime = nil
                selectedSession = sessionList.first
            }

            if let sel = selectedSession {
                currentParent.sessionTitle = sel.title
                currentParent.targetTabId = sel.targetTabId
                currentParent.webLink = sel.webLink
                currentParent.turnId = sel.turnId
                if !sel.sourceEvidence.isEmpty {
                    currentParent.detail = sel.sourceEvidence
                }
            }
        }

        states[provider] = currentParent
        let newStatus = currentParent.status
        let parentDetail = currentParent.detail
        lock.unlock()

        if oldStatus != newStatus {
            notifyObservers(agent: provider, oldStatus: oldStatus, newStatus: newStatus, detail: parentDetail)
        }
    }

    public func checkAutoInspect(frontmostBundleId: String?) {
        guard let bundleId = frontmostBundleId else { return }
        lock.lock()

        let now = Date()

        for agent in AgentID.allCases {
            if agent == .chatgpt { continue }

            guard var info = states[agent] else { continue }
            let isFocused = (agent.bundleIdentifier == bundleId)

            if isFocused && info.status == .done {
                if let start = info.focusedStartTime {
                    let duration = now.timeIntervalSince(start)
                    if duration >= 5.0 {
                        info.focusedStartTime = nil
                        states[agent] = info
                        lock.unlock()
                        markChecked(for: agent)
                        return
                    }
                } else {
                    info.focusedStartTime = now
                    states[agent] = info
                }
            } else if !isFocused {
                if info.focusedStartTime != nil {
                    info.focusedStartTime = nil
                    states[agent] = info
                }
            }
        }

        lock.unlock()
    }

    public func getAvailability(for agent: AgentID) -> ProviderAvailability {
        lock.lock()
        defer { lock.unlock() }
        if let usage = AgentUsageStore.shared.getUsage(for: agent) {
            return usage.availability
        }
        return states[agent]?.availability ?? .unknown
    }

    public func updateAvailability(for agent: AgentID, availability: ProviderAvailability) {
        lock.lock()
        if var info = states[agent] {
            let oldAvail = info.availability
            info.availability = availability
            states[agent] = info
            lock.unlock()
            if oldAvail != availability {
                notifyObservers(agent: agent, oldStatus: info.status, newStatus: info.status, detail: info.detail)
            }
            if availability == .available {
                reconcileQuotaRecovery(for: agent)
            }
        } else {
            lock.unlock()
        }
    }

    public func reconcileQuotaRecovery(for agent: AgentID) {
        lock.lock()
        var currentSessions = trackedSessions[agent] ?? [:]
        var changed = false

        for (sessionId, var session) in currentSessions {
            if session.status == .blocked {
                let reason = (session.attentionReason ?? "").lowercased()
                let sensor = (session.sensorReason ?? "").lowercased()
                let isQuotaBlocked = reason.contains("rate_limit") ||
                                     reason.contains("rate limit") ||
                                     reason.contains("quota") ||
                                     reason.contains("429") ||
                                     reason.contains("limit reached") ||
                                     reason.contains("overloaded") ||
                                     sensor.contains("rate_limit") ||
                                     sensor.contains("quota")

                let isGenuinePermission = reason.contains("permission") ||
                                          reason.contains("approve") ||
                                          reason.contains("confirm") ||
                                          reason.contains("ask_") ||
                                          reason.contains("askuser") ||
                                          sensor.contains("permission")

                if isQuotaBlocked && !isGenuinePermission {
                    session.status = .idle
                    session.attentionReason = nil
                    session.sourceEvidence = "Quota Restored"
                    session.sensorReason = "Quota Restored"
                    currentSessions[sessionId] = session
                    changed = true
                }
            }
        }

        if changed {
            trackedSessions[agent] = currentSessions
            lock.unlock()
            syncSessions(for: agent, activeSessions: Array(currentSessions.values), processRunning: true)
        } else {
            lock.unlock()
        }
    }

    public func getStatus(for agent: AgentID) -> AgentInfo {
        lock.lock()
        defer { lock.unlock() }
        var info = states[agent] ?? AgentInfo(id: agent, status: .off)
        if let usage = AgentUsageStore.shared.getUsage(for: agent) {
            info.availability = usage.availability
        }
        return info
    }

    public func getAllStates() -> [AgentID: AgentInfo] {
        lock.lock()
        defer { lock.unlock() }
        var copy = states
        for agent in AgentID.allCases {
            var info = copy[agent] ?? AgentInfo(id: agent, status: .off)
            if let usage = AgentUsageStore.shared.getUsage(for: agent) {
                info.availability = usage.availability
            }
            copy[agent] = info
        }
        return copy
    }

    public static func canonicalPriorityRank(for info: AgentInfo) -> Int {
        if info.effectiveDisplayStatus == .blocked {
            return 100
        }
        if info.effectiveDisplayStatus == .monitorUnavailable {
            return 35 // Surfaces warning if all else is idle, but respects real active working/done
        }
        if info.status == .done && info.availability != .quotaExhausted {
            return 80
        }
        if info.status == .working && info.availability != .quotaExhausted {
            return 60
        }
        if info.effectiveDisplayStatus == .quotaRestored {
            return 40
        }
        if info.effectiveDisplayStatus == .quotaExhausted {
            return 30
        }
        if info.status == .idle && info.status != .off {
            return 20
        }
        return 0
    }

    public func getHighestPriorityAgent() -> AgentInfo? {
        lock.lock()
        defer { lock.unlock() }

        var resolvedList: [AgentInfo] = []
        for agent in AgentID.allCases where ConfigManager.shared.isAgentMonitored(agent) {
            var info = states[agent] ?? AgentInfo(id: agent, status: .off)
            if let usage = AgentUsageStore.shared.getUsage(for: agent) {
                info.availability = usage.availability
            }
            resolvedList.append(info)
        }

        let sorted = resolvedList.sorted { a, b in
            let rankA = AgentStore.canonicalPriorityRank(for: a)
            let rankB = AgentStore.canonicalPriorityRank(for: b)
            if rankA != rankB {
                return rankA > rankB
            }
            return a.lastUpdated > b.lastUpdated
        }

        guard let top = sorted.first, AgentStore.canonicalPriorityRank(for: top) > 0 else {
            lastTopAgentID = nil
            lastTopStatus = nil
            return nil
        }

        let now = Date()
        if let lastAgentID = lastTopAgentID, let lastStatus = lastTopStatus {
            let elapsed = now.timeIntervalSince(lastTopTime)
            if elapsed < 5.0 {
                let existingRank = resolvedList.first(where: { $0.id == lastAgentID }).map { AgentStore.canonicalPriorityRank(for: $0) } ?? 0
                let topRank = AgentStore.canonicalPriorityRank(for: top)
                if topRank <= existingRank {
                    if let existing = states[lastAgentID], existing.status == lastStatus {
                        return existing
                    }
                }
            }
        }

        lastTopAgentID = top.id
        lastTopStatus = top.status
        lastTopTime = now
        return top
    }

    public func overallSummary() -> String {
        lock.lock()
        defer { lock.unlock() }

        let monitored = AgentID.allCases.filter { ConfigManager.shared.isAgentMonitored($0) }
        if monitored.isEmpty {
            return "-"
        }

        let visible = monitored.filter { agent in
            let info = states[agent] ?? AgentInfo(id: agent, status: .off)
            return info.status != .off && info.effectiveDisplayStatus != .off
        }

        if visible.isEmpty {
            return "⚫"
        }

        return visible.map { agent in
            let info = states[agent] ?? AgentInfo(id: agent, status: .off)
            let customCfg = ConfigManager.shared.getAgentConfig(for: agent)

            let thinkingDur: TimeInterval? = info.thinkingStartTime != nil ? Date().timeIntervalSince(info.thinkingStartTime!) : nil
            let displayStatus = info.effectiveDisplayStatus
            let badge = displayStatus.badge(theme: currentTheme, thinkingDuration: thinkingDur, overworkThresholdMinutes: overworkThresholdMinutes)

            let tag = customCfg?.shortTag ?? agent.shortTag
            return "\(tag):\(badge)"
        }.joined(separator: " ")
    }

    public func compactSummary() -> String {
        lock.lock()
        defer { lock.unlock() }

        var resolvedList: [AgentInfo] = []
        for agent in AgentID.allCases where ConfigManager.shared.isAgentMonitored(agent) {
            var info = states[agent] ?? AgentInfo(id: agent, status: .off)
            if let usage = AgentUsageStore.shared.getUsage(for: agent) {
                info.availability = usage.availability
            }
            resolvedList.append(info)
        }

        let sorted = resolvedList.sorted { a, b in
            let rankA = AgentStore.canonicalPriorityRank(for: a)
            let rankB = AgentStore.canonicalPriorityRank(for: b)
            if rankA != rankB {
                return rankA > rankB
            }
            return a.lastUpdated > b.lastUpdated
        }

        guard let topAgentInfo = sorted.first, AgentStore.canonicalPriorityRank(for: topAgentInfo) >= 30 else {
            // Check idle among monitored
            let anyIdle = resolvedList.contains { $0.status == .idle && $0.effectiveDisplayStatus == .idle }
            if anyIdle {
                return "⚪"
            }
            return "⚫"
        }

        let topRank = AgentStore.canonicalPriorityRank(for: topAgentInfo)
        let sameRankAgents = sorted.filter { AgentStore.canonicalPriorityRank(for: $0) == topRank }

        let customCfg = ConfigManager.shared.getAgentConfig(for: topAgentInfo.id)
        let tag = customCfg?.shortTag ?? topAgentInfo.id.shortTag
        let badge = topAgentInfo.effectiveDisplayStatus.badge(theme: currentTheme)

        let extraCount = sameRankAgents.count - 1
        if extraCount > 0 {
            return "\(tag)\(badge) +\(extraCount)"
        } else {
            return "\(tag)\(badge)"
        }
    }
}
