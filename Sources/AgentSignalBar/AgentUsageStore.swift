import Foundation

public struct AgentUsageData: Codable {
    public var agent: AgentID
    public var sessionLimitPercent: Double?     // e.g. 12.0 (% used or % remaining)
    public var sessionResetText: String?        // e.g. "resets in 3h 02m"
    public var weeklyLimitPercent: Double?      // e.g. 46.0
    public var weeklyResetText: String?         // e.g. "resets Mon 10:59 PM" or "resets Aug 15"
    public var resetCardCount: Int?             // e.g. 1 (1 reset card available for Codex)
    public var resetCardExpiryText: String?     // e.g. "Expires 8/12, 7:51 PM GMT+2"
    public var extraMetricText: String?         // e.g. "Claude/GPT: 100% remaining"
    public var isPercentUsed: Bool              // true if % represents "used", false if "remaining/left"
    public var isLiveSource: Bool               // true if parsed from live local source or POST /usage
    public var quotaSource: String              // e.g. "plan-usage-history.json", "manual_config", "none"
    public var quotaTimestamp: Date?            // Actual sample timestamp from log/file (NOT agent-status lastUpdated)
    public var parserDecision: String           // e.g. "parsed_live_sample", "no_live_disk_file", "user_config"
    public var freshness: String                // "Fresh", "Stale", or "Unavailable"
    public var lastUpdated: Date

    public init(
        agent: AgentID,
        sessionLimitPercent: Double? = nil,
        sessionResetText: String? = nil,
        weeklyLimitPercent: Double? = nil,
        weeklyResetText: String? = nil,
        resetCardCount: Int? = nil,
        resetCardExpiryText: String? = nil,
        extraMetricText: String? = nil,
        isPercentUsed: Bool = true,
        isLiveSource: Bool = false,
        quotaSource: String = "none",
        quotaTimestamp: Date? = nil,
        parserDecision: String = "no_live_disk_file",
        freshness: String? = nil,
        lastUpdated: Date = Date()
    ) {
        self.agent = agent
        self.sessionLimitPercent = sessionLimitPercent
        self.sessionResetText = sessionResetText
        self.weeklyLimitPercent = weeklyLimitPercent
        self.weeklyResetText = weeklyResetText
        self.resetCardCount = resetCardCount
        self.resetCardExpiryText = resetCardExpiryText
        self.extraMetricText = extraMetricText
        self.isPercentUsed = isPercentUsed
        self.isLiveSource = isLiveSource
        self.quotaSource = quotaSource
        self.quotaTimestamp = quotaTimestamp
        self.parserDecision = parserDecision
        self.lastUpdated = lastUpdated

        if let f = freshness {
            self.freshness = f
        } else if !isLiveSource {
            self.freshness = "Unavailable"
        } else if let ts = quotaTimestamp, Date().timeIntervalSince(ts) > 86400 {
            self.freshness = "Stale"
        } else {
            self.freshness = "Fresh"
        }
    }
}

public final class AgentUsageStore: @unchecked Sendable {
    public static let shared = AgentUsageStore()

    private var usageData: [AgentID: AgentUsageData] = [:]
    private let lock = NSLock()

    private init() {
        reloadFromConfig()
    }

    public func reloadFromConfig() {
        lock.lock()
        defer { lock.unlock() }

        let cfgQuotas = ConfigManager.shared.config.quotas ?? [:]

        for agent in AgentID.allCases {
            let q = cfgQuotas[agent.rawValue]
            usageData[agent] = AgentUsageData(
                agent: agent,
                sessionLimitPercent: q?.sessionPercent,
                sessionResetText: q?.sessionResetText,
                weeklyLimitPercent: q?.weeklyPercent,
                weeklyResetText: q?.weeklyResetText,
                resetCardCount: q?.resetCardCount,
                resetCardExpiryText: q?.resetCardExpiryText,
                extraMetricText: q?.extraMetricText,
                isPercentUsed: q?.isPercentUsed ?? true,
                isLiveSource: false,
                quotaSource: "config.json",
                quotaTimestamp: nil,
                parserDecision: "loaded_from_config",
                freshness: "Unavailable",
                lastUpdated: Date()
            )
        }
    }

    public func updateUsage(for agent: AgentID, data: AgentUsageData) {
        lock.lock()
        let existing = usageData[agent]

        // Prevent non-live config fallbacks from overwriting a live source
        if let existing = existing, existing.isLiveSource && !data.isLiveSource {
            lock.unlock()
            return
        }

        let hasChanged = existing == nil ||
            existing?.sessionLimitPercent != data.sessionLimitPercent ||
            existing?.sessionResetText != data.sessionResetText ||
            existing?.weeklyLimitPercent != data.weeklyLimitPercent ||
            existing?.weeklyResetText != data.weeklyResetText ||
            existing?.extraMetricText != data.extraMetricText ||
            existing?.isLiveSource != data.isLiveSource

        usageData[agent] = data
        lock.unlock()

        // Only save to disk if values have genuinely changed
        if hasChanged {
            var cfg = ConfigManager.shared.config
            var currentQuotas = cfg.quotas ?? [:]
            currentQuotas[agent.rawValue] = AgentQuotaConfig(
                sessionPercent: data.sessionLimitPercent,
                sessionResetText: data.sessionResetText,
                weeklyPercent: data.weeklyLimitPercent,
                weeklyResetText: data.weeklyResetText,
                extraMetricText: data.extraMetricText,
                resetCardCount: data.resetCardCount,
                resetCardExpiryText: data.resetCardExpiryText,
                isPercentUsed: data.isPercentUsed
            )
            cfg.quotas = currentQuotas
            ConfigManager.shared.saveConfig(cfg)
        }
    }

    public func getUsage(for agent: AgentID) -> AgentUsageData? {
        lock.lock()
        defer { lock.unlock() }
        return usageData[agent]
    }

    public func getAllUsage() -> [AgentID: AgentUsageData] {
        lock.lock()
        defer { lock.unlock() }
        return usageData
    }

    // Helper to generate clean ASCII Progress Bar e.g. [█░░░░░░░░░]
    public static func makeProgressBar(percent: Double, totalBlocks: Int = 10, isUsed: Bool = true) -> String {
        let clamped = max(0.0, min(100.0, percent))
        let filledCount = Int(round((clamped / 100.0) * Double(totalBlocks)))
        let emptyCount = max(0, totalBlocks - filledCount)

        let filled = String(repeating: "█", count: filledCount)
        let empty = String(repeating: "░", count: emptyCount)
        return "[\(filled)\(empty)]"
    }
}
