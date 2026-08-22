import Foundation

public struct ModelFamilyQuota: Codable, Sendable, Equatable {
    public var name: String
    public var sessionLimitPercent: Double?
    public var sessionResetText: String?
    public var weeklyLimitPercent: Double?
    public var weeklyResetText: String?
    public var isPercentUsed: Bool

    public var isExhausted: Bool {
        if isPercentUsed {
            if let session = sessionLimitPercent, session >= 100.0 { return true }
            if let weekly = weeklyLimitPercent, weekly >= 100.0 { return true }
        } else {
            if let session = sessionLimitPercent, session <= 0.0 { return true }
            if let weekly = weeklyLimitPercent, weekly <= 0.0 { return true }
        }
        return false
    }

    public var sessionRemainingPercent: Double? {
        ModelFamilyQuota.normalizeRemaining(raw: sessionLimitPercent, isPercentUsed: isPercentUsed)
    }

    public var weeklyRemainingPercent: Double? {
        ModelFamilyQuota.normalizeRemaining(raw: weeklyLimitPercent, isPercentUsed: isPercentUsed)
    }

    public static func normalizeRemaining(raw: Double?, isPercentUsed: Bool) -> Double? {
        guard let raw = raw else { return nil }
        if isPercentUsed {
            return max(0.0, min(100.0, 100.0 - raw))
        } else {
            return max(0.0, min(100.0, raw))
        }
    }

    public init(
        name: String,
        sessionLimitPercent: Double? = nil,
        sessionResetText: String? = nil,
        weeklyLimitPercent: Double? = nil,
        weeklyResetText: String? = nil,
        isPercentUsed: Bool = false
    ) {
        self.name = name
        self.sessionLimitPercent = sessionLimitPercent
        self.sessionResetText = sessionResetText
        self.weeklyLimitPercent = weeklyLimitPercent
        self.weeklyResetText = weeklyResetText
        self.isPercentUsed = isPercentUsed
    }
}

public struct AgentUsageData: Codable, Sendable, Equatable {
    public var agent: AgentID
    public var sessionLimitPercent: Double?     // e.g. 12.0 (% used or % remaining)
    public var sessionResetText: String?        // e.g. "resets in 3h 02m"
    public var weeklyLimitPercent: Double?      // e.g. 46.0
    public var weeklyResetText: String?         // e.g. "resets Mon 10:59 PM" or "resets Aug 15"
    public var resetCardCount: Int?             // e.g. 1 (1 reset card available for Codex)
    public var resetCardExpiryText: String?     // e.g. "Expires 8/12, 7:51 PM GMT+2"
    public var extraMetricText: String?         // e.g. "Claude/GPT: 100% remaining"
    public var modelFamilies: [ModelFamilyQuota]
    public var isPercentUsed: Bool              // true if % represents "used", false if "remaining/left"
    public var isLiveSource: Bool               // true if parsed from live local source or POST /usage
    public var quotaSource: String              // e.g. "plan-usage-history.json", "manual_config", "none"
    public var quotaTimestamp: Date?            // Actual sample timestamp from log/file (NOT agent-status lastUpdated)
    public var parserDecision: String           // e.g. "parsed_live_sample", "no_live_disk_file", "user_config"
    public var sourceAuthority: String?         // "live_first_party", "injected_test", "loaded_from_config"
    public var freshness: String                // "Fresh", "Stale", or "Unavailable"
    public var lastSuccessfulRefresh: Date?     // Timestamp of the last successful live query
    public var lastUpdated: Date

    public var sessionRemainingPercent: Double? {
        ModelFamilyQuota.normalizeRemaining(raw: sessionLimitPercent, isPercentUsed: isPercentUsed)
    }

    public var weeklyRemainingPercent: Double? {
        ModelFamilyQuota.normalizeRemaining(raw: weeklyLimitPercent, isPercentUsed: isPercentUsed)
    }

    public init(
        agent: AgentID,
        sessionLimitPercent: Double? = nil,
        sessionResetText: String? = nil,
        weeklyLimitPercent: Double? = nil,
        weeklyResetText: String? = nil,
        resetCardCount: Int? = nil,
        resetCardExpiryText: String? = nil,
        extraMetricText: String? = nil,
        modelFamilies: [ModelFamilyQuota] = [],
        isPercentUsed: Bool = true,
        isLiveSource: Bool = false,
        quotaSource: String = "none",
        sourceAuthority: String? = nil,
        quotaTimestamp: Date? = nil,
        lastSuccessfulRefresh: Date? = nil,
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
        self.modelFamilies = modelFamilies
        self.isPercentUsed = isPercentUsed
        self.isLiveSource = isLiveSource
        self.quotaSource = quotaSource
        self.sourceAuthority = sourceAuthority ?? (isLiveSource ? "live_first_party" : "loaded_from_config")
        self.quotaTimestamp = quotaTimestamp
        self.lastSuccessfulRefresh = lastSuccessfulRefresh ?? (isLiveSource ? lastUpdated : nil)
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

    public var isQuotaExhausted: Bool {
        guard isLiveSource, freshness != "Unavailable" else { return false }
        if !modelFamilies.isEmpty {
            let exhaustedCount = modelFamilies.filter { $0.isExhausted }.count
            return exhaustedCount == modelFamilies.count
        }
        if isPercentUsed {
            if let session = sessionLimitPercent, session >= 100.0 { return true }
            if let weekly = weeklyLimitPercent, weekly >= 100.0 { return true }
        } else {
            if let session = sessionLimitPercent, session <= 0.0 { return true }
            if let weekly = weeklyLimitPercent, weekly <= 0.0 { return true }
        }
        return false
    }

    public var availability: ProviderAvailability {
        guard isLiveSource, freshness != "Unavailable" else {
            return .unknown
        }
        if !modelFamilies.isEmpty {
            let total = modelFamilies.count
            let exhaustedCount = modelFamilies.filter { $0.isExhausted }.count
            if exhaustedCount == 0 {
                return .available
            } else if exhaustedCount == total {
                return .quotaExhausted
            } else {
                return .limited
            }
        }
        if isQuotaExhausted {
            return .quotaExhausted
        }
        return .available
    }
}

public final class AgentUsageStore: @unchecked Sendable {
    public static let shared = AgentUsageStore()

    private var usageData: [AgentID: AgentUsageData] = [:]
    private var previousAuthoritativeExhausted: [AgentID: Bool] = [:]
    private let lock = NSLock()

    private init() {
        reloadFromConfig()
    }

    public func setPreviousAuthoritativeExhausted(for agent: AgentID, exhausted: Bool) {
        lock.lock()
        previousAuthoritativeExhausted[agent] = exhausted
        lock.unlock()
    }

    public func reloadFromConfig() {
        lock.lock()
        defer { lock.unlock() }

        let cfgQuotas = ConfigManager.shared.config.quotas ?? [:]

        for agent in AgentID.allCases {
            let q = cfgQuotas[agent.rawValue]
            var families: [ModelFamilyQuota] = []
            if agent != .antigravity, let cfgFamilies = q?.modelFamilies {
                for cf in cfgFamilies {
                    families.append(ModelFamilyQuota(
                        name: cf.name,
                        sessionLimitPercent: cf.sessionPercent,
                        sessionResetText: cf.sessionResetText,
                        weeklyLimitPercent: cf.weeklyPercent,
                        weeklyResetText: cf.weeklyResetText,
                        isPercentUsed: cf.isPercentUsed ?? false
                    ))
                }
            }
            usageData[agent] = AgentUsageData(
                agent: agent,
                sessionLimitPercent: agent == .antigravity ? nil : q?.sessionPercent,
                sessionResetText: agent == .antigravity ? nil : q?.sessionResetText,
                weeklyLimitPercent: agent == .antigravity ? nil : q?.weeklyPercent,
                weeklyResetText: agent == .antigravity ? nil : q?.weeklyResetText,
                resetCardCount: q?.resetCardCount,
                resetCardExpiryText: q?.resetCardExpiryText,
                extraMetricText: agent == .antigravity ? "Live source unavailable" : q?.extraMetricText,
                modelFamilies: families,
                isPercentUsed: q?.isPercentUsed ?? true,
                isLiveSource: false,
                quotaSource: "none",
                sourceAuthority: "loaded_from_config",
                quotaTimestamp: nil,
                lastSuccessfulRefresh: nil,
                parserDecision: "no_live_disk_file",
                freshness: "Unavailable",
                lastUpdated: Date()
            )
        }
    }

    public func updateUsage(for agent: AgentID, data: AgentUsageData) {
        lock.lock()
        let existing = usageData[agent]

        // Prevent non-live config fallbacks from overwriting a live source
        if let existing = existing, existing.isLiveSource && !data.isLiveSource && (data.quotaSource == "none" || data.sourceAuthority == "loaded_from_config") {
            lock.unlock()
            return
        }

        var toStore = data
        if toStore.isLiveSource && toStore.lastSuccessfulRefresh == nil {
            toStore.lastSuccessfulRefresh = Date()
        } else if !toStore.isLiveSource, let existing = existing, existing.lastSuccessfulRefresh != nil {
            toStore.lastSuccessfulRefresh = existing.lastSuccessfulRefresh
        }

        let hasChanged = existing != toStore

        if toStore.isLiveSource {
            let currentIsExhausted = toStore.isQuotaExhausted || toStore.availability == .quotaExhausted || (toStore.weeklyRemainingPercent ?? 100.0) <= 0.0 || (toStore.sessionRemainingPercent ?? 100.0) <= 0.0 || (!toStore.modelFamilies.isEmpty && toStore.modelFamilies.allSatisfy { $0.isExhausted })
            let wasExhausted = previousAuthoritativeExhausted[agent] ?? false
            if wasExhausted && !currentIsExhausted {
                // Genuine positive recovery transition: previously exhausted -> now available
                AgentStore.shared.setQuotaRestored(for: agent, restored: true)
                AgentStore.shared.reconcileQuotaRecovery(for: agent)
            } else if !currentIsExhausted {
                AgentStore.shared.reconcileQuotaRecovery(for: agent)
            }
            previousAuthoritativeExhausted[agent] = currentIsExhausted
        }

        usageData[agent] = toStore
        lock.unlock()

        // Only save to disk if values have genuinely changed
        if hasChanged {
            var cfg = ConfigManager.shared.config
            var currentQuotas = cfg.quotas ?? [:]
            var cfgFamilies: [ModelFamilyQuotaConfig] = []
            for f in data.modelFamilies {
                cfgFamilies.append(ModelFamilyQuotaConfig(
                    name: f.name,
                    sessionPercent: f.sessionLimitPercent,
                    weeklyPercent: f.weeklyLimitPercent,
                    sessionResetText: f.sessionResetText,
                    weeklyResetText: f.weeklyResetText,
                    isPercentUsed: f.isPercentUsed
                ))
            }
            currentQuotas[agent.rawValue] = AgentQuotaConfig(
                sessionPercent: data.sessionLimitPercent,
                sessionResetText: data.sessionResetText,
                weeklyPercent: data.weeklyLimitPercent,
                weeklyResetText: data.weeklyResetText,
                extraMetricText: data.extraMetricText,
                resetCardCount: data.resetCardCount,
                resetCardExpiryText: data.resetCardExpiryText,
                isPercentUsed: data.isPercentUsed,
                modelFamilies: cfgFamilies.isEmpty ? nil : cfgFamilies
            )
            cfg.quotas = currentQuotas
            ConfigManager.shared.saveConfig(cfg)
        }
    }

    public func markQuotaExhausted(for agent: AgentID) {
        lock.lock()
        var current = usageData[agent] ?? AgentUsageData(agent: agent, isPercentUsed: false, isLiveSource: true)
        current.isLiveSource = true
        current.freshness = "Fresh"
        current.isPercentUsed = false
        current.sessionLimitPercent = 0.0
        current.weeklyLimitPercent = 0.0
        usageData[agent] = current
        previousAuthoritativeExhausted[agent] = true
        lock.unlock()

        AgentStore.shared.updateAvailability(for: agent, availability: .quotaExhausted)
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
