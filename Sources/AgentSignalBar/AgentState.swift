import Foundation
import AppKit

public enum BadgeThemeMode: String, Codable, CaseIterable {
    case classic = "classic"
    case funEmoji = "funEmoji"

    public var displayName: String {
        switch self {
        case .classic: return "Classic Colored Balls (⚪🟡🟢🔴⚫)"
        case .funEmoji: return "Fun Emojis (🫥🤔🥵🐶🥶😴🤯)"
        }
    }
}

public enum AgentID: String, Codable, CaseIterable {
    case chatgpt = "chatgpt"
    case codex = "codex"
    case claude = "claude"
    case antigravity = "antigravity"

    public var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT Web"
        case .codex: return "Codex Desktop"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }

    public var symbol: String {
        switch self {
        case .chatgpt: return "💬"
        case .codex: return "💻"
        case .claude: return "🤖"
        case .antigravity: return "🚀"
        }
    }

    public var shortTag: String {
        switch self {
        case .chatgpt: return "GPT"
        case .codex: return "CDX"
        case .claude: return "CLD"
        case .antigravity: return "AGY"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chatgpt: return "com.google.Chrome"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .antigravity: return "com.google.antigravity"
        }
    }
}

public enum AgentStatus: String, Codable {
    case off = "off"
    case idle = "idle"
    case working = "working"
    case done = "done"
    case blocked = "blocked"
    case quotaExceeded = "quotaExceeded"

    public func badge(theme: BadgeThemeMode = .classic, thinkingDuration: TimeInterval? = nil, overworkThresholdMinutes: Int = 10) -> String {
        switch theme {
        case .classic:
            switch self {
            case .off: return "⚫"
            case .idle: return "⚪"
            case .working: return "🟡"
            case .done: return "🟢"
            case .blocked: return "🔴"
            case .quotaExceeded: return "⚫"
            }
        case .funEmoji:
            switch self {
            case .off: return "😴"
            case .idle: return "🫥"
            case .working:
                if let dur = thinkingDuration, dur >= Double(overworkThresholdMinutes * 60) {
                    return "🥵"
                }
                return "🤔"
            case .done: return "🐶"
            case .blocked: return "🥶"
            case .quotaExceeded: return "🤯"
            }
        }
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

public struct ChatGPTTabInfo: Codable {
    public let title: String
    public let url: String
    public let status: String

    public init(title: String, url: String, status: String) {
        self.title = title
        self.url = url
        self.status = status
    }
}

public struct AgentInfo: Codable {
    public let id: AgentID
    public var status: AgentStatus
    public var lastUpdated: Date
    public var detail: String?
    public var thinkingStartTime: Date?
    public var lastDurationSeconds: TimeInterval?
    public var tokenCount: Int?
    public var activeSessionCount: Int
    public var sessionTitle: String?
    public var webLink: String?
    public var focusedStartTime: Date?
    public var openTabs: [ChatGPTTabInfo]

    public init(
        id: AgentID,
        status: AgentStatus = .off,
        lastUpdated: Date = Date(),
        detail: String? = nil,
        thinkingStartTime: Date? = nil,
        lastDurationSeconds: TimeInterval? = nil,
        tokenCount: Int? = nil,
        activeSessionCount: Int = 1,
        sessionTitle: String? = nil,
        webLink: String? = nil,
        focusedStartTime: Date? = nil,
        openTabs: [ChatGPTTabInfo] = []
    ) {
        self.id = id
        self.status = status
        self.lastUpdated = lastUpdated
        self.detail = detail
        self.thinkingStartTime = thinkingStartTime
        self.lastDurationSeconds = lastDurationSeconds
        self.tokenCount = tokenCount
        self.activeSessionCount = activeSessionCount
        self.sessionTitle = sessionTitle
        self.webLink = webLink
        self.focusedStartTime = focusedStartTime
        self.openTabs = openTabs
    }
}

public final class AgentStore: @unchecked Sendable {
    public static let shared = AgentStore()

    private var states: [AgentID: AgentInfo] = [:]
    private let lock = NSLock()

    public var currentTheme: BadgeThemeMode = .classic
    public var overworkThresholdMinutes: Int = 10

    public var onStateChanged: ((AgentID, AgentStatus, AgentStatus, String?) -> Void)?

    private init() {
        let savedThemeStr = ConfigManager.shared.config.badgeTheme ?? "classic"
        self.currentTheme = BadgeThemeMode(rawValue: savedThemeStr) ?? .classic
        self.overworkThresholdMinutes = ConfigManager.shared.config.overworkThresholdMinutes ?? 10

        for agent in AgentID.allCases {
            states[agent] = AgentInfo(id: agent, status: .off)
        }
    }

    public func updateStatus(
        for agent: AgentID,
        status: AgentStatus,
        detail: String? = nil,
        tokenCount: Int? = nil,
        sessionCount: Int? = nil,
        sessionTitle: String? = nil,
        webLink: String? = nil,
        openTabs: [ChatGPTTabInfo]? = nil
    ) {
        lock.lock()
        var current = states[agent] ?? AgentInfo(id: agent)
        let oldStatus = current.status

        current.status = status
        current.lastUpdated = Date()
        if let d = detail { current.detail = d }
        if let t = tokenCount { current.tokenCount = t }
        if let s = sessionCount { current.activeSessionCount = max(1, s) }
        if let title = sessionTitle { current.sessionTitle = title }
        if let link = webLink { current.webLink = link }
        if let tabs = openTabs { current.openTabs = tabs }

        if status == .working {
            if oldStatus != .working {
                current.thinkingStartTime = Date()
            }
        } else if oldStatus == .working {
            if let start = current.thinkingStartTime {
                current.lastDurationSeconds = Date().timeIntervalSince(start)
            }
            current.thinkingStartTime = nil
        }

        states[agent] = current
        lock.unlock()

        if oldStatus != status {
            onStateChanged?(agent, oldStatus, status, detail)
        }
    }

    public func markChecked(for agent: AgentID) {
        lock.lock()
        var current = states[agent] ?? AgentInfo(id: agent)
        if current.status == .done || current.status == .blocked {
            let oldStatus = current.status
            current.status = .idle
            current.detail = "\(agent.displayName) inspected by user"
            current.focusedStartTime = nil
            states[agent] = current
            lock.unlock()
            onStateChanged?(agent, oldStatus, .idle, current.detail)
            return
        }
        lock.unlock()
    }

    public func checkAutoInspect(frontmostBundleId: String?) {
        guard let bundleId = frontmostBundleId else { return }
        lock.lock()

        let now = Date()

        for agent in AgentID.allCases {
            guard var info = states[agent] else { continue }

            let isFocused = (agent.bundleIdentifier == bundleId)

            if isFocused && (info.status == .done || info.status == .blocked) {
                if let start = info.focusedStartTime {
                    let duration = now.timeIntervalSince(start)
                    if duration >= 4.0 {
                        let oldStatus = info.status
                        info.status = .idle
                        info.detail = "Auto-inspected after 5s focus"
                        info.focusedStartTime = nil
                        states[agent] = info
                        lock.unlock()
                        onStateChanged?(agent, oldStatus, .idle, info.detail)
                        return
                    }
                } else {
                    info.focusedStartTime = now
                    states[agent] = info
                }
            } else if !isFocused {
                if info.focusedStartTime != nil {
                    if info.status == .done || info.status == .blocked {
                        let oldStatus = info.status
                        info.status = .idle
                        info.detail = "Auto-inspected upon switching focus"
                        info.focusedStartTime = nil
                        states[agent] = info
                        lock.unlock()
                        onStateChanged?(agent, oldStatus, .idle, info.detail)
                        return
                    }
                    info.focusedStartTime = nil
                    states[agent] = info
                }
            }
        }

        lock.unlock()
    }

    public func getStatus(for agent: AgentID) -> AgentInfo {
        lock.lock()
        defer { lock.unlock() }
        return states[agent] ?? AgentInfo(id: agent, status: .off)
    }

    public func getAllStates() -> [AgentID: AgentInfo] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    public func getHighestPriorityAgent() -> AgentInfo? {
        lock.lock()
        defer { lock.unlock() }

        if let red = AgentID.allCases.map({ states[$0] ?? AgentInfo(id: $0) }).first(where: { $0.status == .blocked }) {
            return red
        }
        if let green = AgentID.allCases.map({ states[$0] ?? AgentInfo(id: $0) }).first(where: { $0.status == .done }) {
            return green
        }
        if let yellow = AgentID.allCases.map({ states[$0] ?? AgentInfo(id: $0) }).first(where: { $0.status == .working }) {
            return yellow
        }
        return nil
    }

    public func overallSummary() -> String {
        lock.lock()
        defer { lock.unlock() }

        return AgentID.allCases.map { agent in
            let info = states[agent] ?? AgentInfo(id: agent, status: .off)
            let customCfg = ConfigManager.shared.getAgentConfig(for: agent)

            let thinkingDur: TimeInterval? = info.thinkingStartTime != nil ? Date().timeIntervalSince(info.thinkingStartTime!) : nil
            let badge = info.status.badge(theme: currentTheme, thinkingDuration: thinkingDur, overworkThresholdMinutes: overworkThresholdMinutes)

            let tag = customCfg?.shortTag ?? agent.shortTag
            return "\(tag):\(badge)"
        }.joined(separator: " ")
    }
}
