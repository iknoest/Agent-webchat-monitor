import Foundation

public struct TelegramCommandResult: Sendable, Equatable {
    public let text: String
    public let parseMode: String?

    public init(text: String, parseMode: String? = nil) {
        self.text = text
        self.parseMode = parseMode
    }
}

public protocol TelegramCommandHandler: Sendable {
    func handle(command: String, args: [String], fromChatId: String) async -> TelegramCommandResult?
}

public final class TelegramCommandRouter: @unchecked Sendable {
    public static let shared = TelegramCommandRouter()

    private let lock = NSLock()
    private var customHandlers: [String: TelegramCommandHandler] = [:]

    public init() {}

    private func getCustomHandler(for cmd: String) -> TelegramCommandHandler? {
        lock.lock()
        defer { lock.unlock() }
        return customHandlers[cmd]
    }

    /// Evaluates incoming message. Returns nil if unauthorized or unrecognized without reply.
    public func handleIncomingMessage(_ message: TelegramMessage, configuredChatId: String) async -> TelegramCommandResult? {
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        // 1. Strict Chat ID Authorization Check
        let senderChatId = String(message.chat.id)
        guard !configuredChatId.isEmpty, senderChatId == configuredChatId else {
            // Drop silently: never reply or confirm configuration to unauthorized chats
            return nil
        }

        // 2. Command Parsing
        guard text.hasPrefix("/") else {
            return nil
        }

        let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }

        // Strip bot username if invoked as /command@botname
        var cmd = first.lowercased()
        if let atIdx = cmd.firstIndex(of: "@") {
            cmd = String(cmd[..<atIdx])
        }
        let args = Array(parts.dropFirst())

        // 3. Custom / Future Handlers Seam
        if let custom = getCustomHandler(for: cmd) {
            return await custom.handle(command: cmd, args: args, fromChatId: senderChatId)
        }

        // 4. Built-in Read-Only Commands
        switch cmd {
        case "/status":
            return generateStatusOverview()
        case "/quota":
            return generateQuotaOverview()
        case "/sessions":
            return generateSessionsOverview()
        case "/help", "/start":
            return generateHelpMessage()
        default:
            return nil
        }
    }

    // MARK: - Built-in Command Generators

    public func generateStatusOverview() -> TelegramCommandResult {
        let store = AgentStore.shared
        let config = ConfigManager.shared
        let theme = store.currentTheme

        var lines: [String] = ["AgentSignalBar Status\n"]
        let monitored = AgentID.allCases.filter { config.isAgentMonitored($0) }

        if monitored.isEmpty {
            lines.append("No agents currently enabled under Monitored Agents.")
        } else {
            for agent in monitored {
                let info = store.getStatus(for: agent)
                let badge = info.effectiveDisplayStatus.badge(theme: theme)
                var statusText = info.effectiveDisplayStatus.rawValue.capitalized

                if info.status == .working {
                    if let start = info.thinkingStartTime {
                        let dur = Int(Date().timeIntervalSince(start))
                        if dur >= 60 {
                            statusText = "Working (\(dur / 60)m)"
                        } else {
                            statusText = "Working (\(dur)s)"
                        }
                    } else {
                        statusText = "Working"
                    }
                } else if info.status == .done {
                    statusText = "Done"
                } else if info.status == .blocked {
                    statusText = "Needs You"
                } else if info.status == .idle {
                    statusText = "Idle"
                } else if info.status == .off {
                    statusText = "Closed"
                }

                lines.append("\(badge) \(agent.displayName) — \(statusText)")
            }
        }

        return TelegramCommandResult(text: lines.joined(separator: "\n"))
    }

    public func generateQuotaOverview() -> TelegramCommandResult {
        let config = ConfigManager.shared
        let monitored = AgentID.allCases.filter { config.isAgentMonitored($0) }

        var lines: [String] = ["AgentSignalBar Quota\n"]

        if monitored.isEmpty {
            lines.append("No agents currently enabled under Monitored Agents.")
            return TelegramCommandResult(text: lines.joined(separator: "\n"))
        }

        for agent in monitored {
            let usage = AgentUsageStore.shared.getUsage(for: agent)
            lines.append("\(agent.displayName):")

            if let families = usage?.modelFamilies, !families.isEmpty {
                for mf in families {
                    var parts: [String] = []
                    if let sess = mf.sessionRemainingPercent {
                        var p = "5h: \(Int(sess))% left"
                        if let r = mf.sessionResetText, !r.isEmpty { p += " (\(r))" }
                        parts.append(p)
                    }
                    if let wk = mf.weeklyRemainingPercent {
                        var p = "Weekly: \(Int(wk))% left"
                        if let r = mf.weeklyResetText, !r.isEmpty { p += " (\(r))" }
                        parts.append(p)
                    }
                    if parts.isEmpty {
                        lines.append("• \(mf.name): Quota tracked")
                    } else {
                        lines.append("• \(mf.name): \(parts.joined(separator: " · "))")
                    }
                }
            } else if let usage = usage {
                var parts: [String] = []
                if let sess = usage.sessionRemainingPercent {
                    var p = "Session: \(Int(sess))% left"
                    if let r = usage.sessionResetText, !r.isEmpty { p += " (\(r))" }
                    parts.append(p)
                }
                if let wk = usage.weeklyRemainingPercent {
                    var p = "Weekly: \(Int(wk))% left"
                    if let r = usage.weeklyResetText, !r.isEmpty { p += " (\(r))" }
                    parts.append(p)
                }
                if usage.isQuotaExhausted {
                    lines.append("• Quota Exhausted")
                } else if !parts.isEmpty {
                    lines.append("• \(parts.joined(separator: " · "))")
                } else if let reset = usage.weeklyResetText ?? usage.sessionResetText, !reset.isEmpty {
                    lines.append("• Reset: \(reset)")
                } else {
                    lines.append("• Live disk quota unavailable")
                }
            } else {
                lines.append("• Live disk quota unavailable")
            }
            lines.append("")
        }

        return TelegramCommandResult(text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func generateSessionsOverview() -> TelegramCommandResult {
        let store = AgentStore.shared
        let config = ConfigManager.shared
        let monitored = Set(AgentID.allCases.filter { config.isAgentMonitored($0) })
        let allSessions = store.getAllSessions().filter { monitored.contains($0.provider) }

        var lines: [String] = ["AgentSignalBar Sessions\n"]

        if allSessions.isEmpty {
            lines.append("No active sessions currently tracked.")
        } else {
            for sess in allSessions {
                let badge = sess.status.badge(theme: store.currentTheme)
                let safeProject = TelegramPrivacySafeContext.resolveSafeProjectContext(agent: sess.provider, session: sess)
                var stateDesc = sess.status.rawValue.capitalized
                if sess.status == .working, let start = sess.thinkingStartTime {
                    let dur = Int(Date().timeIntervalSince(start))
                    stateDesc = "Working (\(dur)s)"
                }
                lines.append("\(badge) [\(sess.provider.shortTag)] \(safeProject) — \(stateDesc)")
            }
        }

        return TelegramCommandResult(text: lines.joined(separator: "\n"))
    }

    public func generateHelpMessage() -> TelegramCommandResult {
        let text = """
        AgentSignalBar Bot Commands:

        /status — Compact overview of monitored AI agents
        /quota — Model quota availability & reset windows
        /sessions — Active tracked sessions summary
        /help — Show this help message
        """
        return TelegramCommandResult(text: text)
    }
}
