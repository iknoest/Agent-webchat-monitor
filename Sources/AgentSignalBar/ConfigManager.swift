import Foundation
import AppKit

public struct StatusBadgeItem: Codable {
    public var classic: String
    public var funEmoji: String

    public init(classic: String, funEmoji: String) {
        self.classic = classic
        self.funEmoji = funEmoji
    }
}

public struct StatusBadgesConfig: Codable {
    public var idle: StatusBadgeItem
    public var working: StatusBadgeItem
    public var done: StatusBadgeItem
    public var blocked: StatusBadgeItem
    public var off: StatusBadgeItem
    public var overworking: StatusBadgeItem?
    public var quotaDepleted: StatusBadgeItem?

    public init(
        idle: StatusBadgeItem = StatusBadgeItem(classic: "⚪", funEmoji: "🫥"),
        working: StatusBadgeItem = StatusBadgeItem(classic: "🟡", funEmoji: "🤔"),
        done: StatusBadgeItem = StatusBadgeItem(classic: "🟢", funEmoji: "🐶"),
        blocked: StatusBadgeItem = StatusBadgeItem(classic: "🔴", funEmoji: "🥶"),
        off: StatusBadgeItem = StatusBadgeItem(classic: "⚫", funEmoji: "😴"),
        overworking: StatusBadgeItem = StatusBadgeItem(classic: "🟡🔥", funEmoji: "🥵"),
        quotaDepleted: StatusBadgeItem = StatusBadgeItem(classic: "🔴⚠️", funEmoji: "🤯")
    ) {
        self.idle = idle
        self.working = working
        self.done = done
        self.blocked = blocked
        self.off = off
        self.overworking = overworking
        self.quotaDepleted = quotaDepleted
    }

    public static var defaultConfig: StatusBadgesConfig {
        return StatusBadgesConfig()
    }
}

public struct AgentCustomConfig: Codable {
    public var displayName: String
    public var symbol: String
    public var shortTag: String
    public var customIconPath: String?
}

public struct AgentQuotaConfig: Codable {
    public var sessionPercent: Double?
    public var sessionResetText: String?
    public var weeklyPercent: Double?
    public var weeklyResetText: String?
    public var extraMetricText: String?
    public var resetCardCount: Int?
    public var resetCardExpiryText: String?
    public var isPercentUsed: Bool?
}

public struct AppConfig: Codable {
    public var summaryFormat: String
    public var badgeTheme: String?  // "classic" or "funEmoji"
    public var overworkThresholdMinutes: Int? // default 10
    public var notificationsEnabled: Bool? // default true
    public var doneSoundName: String? // default "Glass"
    public var attentionSoundName: String? // default "Basso"
    public var customMainIconPath: String?
    public var agents: [String: AgentCustomConfig]
    public var quotas: [String: AgentQuotaConfig]?
    public var statusBadges: StatusBadgesConfig

    public static var defaultConfig: AppConfig {
        return AppConfig(
            summaryFormat: "[{GPT} {CDX} {CLD} {AGY}]",
            badgeTheme: "classic",
            overworkThresholdMinutes: 10,
            notificationsEnabled: true,
            doneSoundName: "Glass",
            attentionSoundName: "Basso",
            customMainIconPath: nil,
            agents: [
                "chatgpt": AgentCustomConfig(displayName: "ChatGPT Web", symbol: "💬", shortTag: "GPT", customIconPath: "~/.config/AgentSignalBar/icons/chatgpt.png"),
                "codex": AgentCustomConfig(displayName: "Codex Desktop", symbol: "💻", shortTag: "CDX", customIconPath: "~/.config/AgentSignalBar/icons/codex.png"),
                "claude": AgentCustomConfig(displayName: "Claude Code", symbol: "🤖", shortTag: "CLD", customIconPath: "~/.config/AgentSignalBar/icons/claude.png"),
                "antigravity": AgentCustomConfig(displayName: "Antigravity", symbol: "🚀", shortTag: "AGY", customIconPath: "~/.config/AgentSignalBar/icons/antigravity.png")
            ],
            quotas: [
                "antigravity": AgentQuotaConfig(
                    sessionPercent: 40.0,
                    sessionResetText: "resets in 23m",
                    weeklyPercent: 67.0,
                    weeklyResetText: "resets in 5d 9h",
                    extraMetricText: "Claude & GPT: 5-Hr 100% · Weekly 100% left",
                    isPercentUsed: false
                ),
                "claude": AgentQuotaConfig(
                    sessionPercent: 12.0,
                    sessionResetText: "resets in 3h 02m",
                    weeklyPercent: 46.0,
                    weeklyResetText: "resets Mon 10:59 PM",
                    isPercentUsed: true
                ),
                "codex": AgentQuotaConfig(
                    weeklyPercent: 89.0,
                    weeklyResetText: "resets Aug 15",
                    resetCardCount: 1,
                    resetCardExpiryText: "Expires 8/12, 7:51 PM GMT+2",
                    isPercentUsed: false
                ),
                "chatgpt": AgentQuotaConfig(
                    weeklyPercent: 100.0,
                    weeklyResetText: "Plus Plan Active",
                    extraMetricText: "Rate Limit: Normal",
                    isPercentUsed: false
                )
            ],
            statusBadges: StatusBadgesConfig.defaultConfig
        )
    }
}

public final class ConfigManager: @unchecked Sendable {
    public static let shared = ConfigManager()

    public private(set) var config: AppConfig
    private let configPath: String

    private init() {
        let home = NSHomeDirectory()
        self.configPath = "\(home)/.config/AgentSignalBar/config.json"
        self.config = AppConfig.defaultConfig
        loadConfig()
    }

    public func getAgentConfig(for agent: AgentID) -> AgentCustomConfig? {
        return config.agents[agent.rawValue]
    }

    public func loadConfig() {
        let fm = FileManager.default

        let dirPath = NSString(string: configPath).deletingLastPathComponent
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }

        let iconsDir = "\(dirPath)/icons"
        if !fm.fileExists(atPath: iconsDir) {
            try? fm.createDirectory(atPath: iconsDir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: configPath) {
            saveConfig(AppConfig.defaultConfig)
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            var decoded = try JSONDecoder().decode(AppConfig.self, from: data)

            // Auto-backfill overworking and quotaDepleted if missing in existing config.json
            var needsSave = false
            if decoded.statusBadges.overworking == nil {
                decoded.statusBadges.overworking = StatusBadgeItem(classic: "🟡🔥", funEmoji: "🥵")
                needsSave = true
            }
            if decoded.statusBadges.quotaDepleted == nil {
                decoded.statusBadges.quotaDepleted = StatusBadgeItem(classic: "🔴⚠️", funEmoji: "🤯")
                needsSave = true
            }

            self.config = decoded
            if needsSave {
                saveConfig(decoded)
            }
            print("✅ Successfully loaded custom config from \(configPath)")
        } catch {
            print("⚠️ Failed to parse config.json, using defaults: \(error)")
        }
    }

    public func saveConfig(_ newConfig: AppConfig) {
        self.config = newConfig
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(newConfig)
            try data.write(to: URL(fileURLWithPath: configPath))
            print("✅ Config saved to \(configPath)")
        } catch {
            print("❌ Failed to save config: \(error)")
        }
    }

    public func openConfigFileInEditor() {
        let url = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.open(url)
    }

    public func openIconsFolder() {
        let home = NSHomeDirectory()
        let iconsDir = "\(home)/.config/AgentSignalBar/icons"
        let url = URL(fileURLWithPath: iconsDir)
        NSWorkspace.shared.open(url)
    }
}
