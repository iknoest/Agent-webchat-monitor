import Foundation
import AppKit

extension Date {
    func relativeString() -> String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

public final class MenuBarManager: NSObject, NSMenuDelegate {
    public static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var refreshTimer: Timer?
    private var lastUsageRefreshTime: Date = Date()
    public private(set) var isRefreshingUsage: Bool = false

    public func setup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "AgentSignalBarStatusItem"
            self.statusItem = item

            if let button = item.button {
                button.title = "AgentBridge"
            }

            let contextMenu = NSMenu()
            contextMenu.delegate = self
            item.menu = contextMenu
            self.menu = contextMenu

            self.updateTitleAndMenu()

            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.scheduleTitleAndMenuUpdate()
            }

            AgentStore.shared.addObserver(id: "MenuBarManager") { [weak self] agent, oldStatus, newStatus, detail in
                NotificationManager.shared.notify(agent: agent, oldStatus: oldStatus, newStatus: newStatus, detail: detail)
                self?.scheduleTitleAndMenuUpdate()
            }
        }
    }

    private var isUpdateScheduled = false
    private var imageCache: [AgentStatus: NSImage] = [:]
    private var displayImageCache: [EffectiveDisplayStatus: NSImage] = [:]
    private var lastRenderedSignature: String = ""
    private var lastRebuildTime: Date = Date.distantPast
    private var pendingThrottledTimer: Timer?

    public func buildMenuForTesting() -> NSMenu {
        let testMenu = NSMenu()
        self.menu = testMenu
        rebuildMenu()
        return testMenu
    }

    private func cachedStatusDotImage(for status: AgentStatus) -> NSImage {
        if let cached = imageCache[status] {
            return cached
        }
        let img = status.statusDotImage()
        imageCache[status] = img
        return img
    }

    private func cachedDisplayDotImage(for status: EffectiveDisplayStatus) -> NSImage {
        if let cached = displayImageCache[status] {
            return cached
        }
        let img = status.statusDotImage()
        displayImageCache[status] = img
        return img
    }

    public private(set) var renderExecutionCount: Int = 0
    public private(set) var activePendingTimerCount: Int = 0
    public var onPerformUpdateTitleAndMenu: (() -> Void)?

    public func resetTestMetrics() {
        lastRenderedSignature = ""
        lastRebuildTime = Date.distantPast
        renderExecutionCount = 0
        activePendingTimerCount = 0
        pendingThrottledTimer?.invalidate()
        pendingThrottledTimer = nil
        onPerformUpdateTitleAndMenu = nil
    }

    public static func getStatusLegendItems(theme: BadgeThemeMode, overworkMinutes: Int = 10) -> [(status: EffectiveDisplayStatus, badge: String, title: String, desc: String)] {
        var items: [(status: EffectiveDisplayStatus, badge: String, title: String, desc: String)] = []

        let blockedBadge = EffectiveDisplayStatus.blocked.badge(theme: theme)
        items.append((.blocked, blockedBadge, "\(blockedBadge) Attention Needed / User Input Required", "Agent is blocked and waiting for user input / permission"))

        let workingBadge = EffectiveDisplayStatus.working.badge(theme: theme)
        items.append((.working, workingBadge, "\(workingBadge) Working / Thinking Active", "Agent is actively running tools, reasoning, or executing tasks"))

        if theme == .funEmoji {
            let overworkBadge = EffectiveDisplayStatus.working.badge(theme: theme, thinkingDuration: Double((overworkMinutes + 1) * 60), overworkThresholdMinutes: overworkMinutes)
            items.append((.working, overworkBadge, "\(overworkBadge) Overworking / Extended Thinking (> \(overworkMinutes)m)", "Agent has been thinking or running tools continuously for over \(overworkMinutes) minutes"))
        }

        let doneBadge = EffectiveDisplayStatus.done.badge(theme: theme)
        items.append((.done, doneBadge, "\(doneBadge) Finished / Task Complete", "Agent finished its task; unread output is ready"))

        let quotaExhaustedBadge = EffectiveDisplayStatus.quotaExhausted.badge(theme: theme)
        let quotaExhaustedLabel = (theme == .funEmoji) ? "\(quotaExhaustedBadge) Quota Exhausted / Rate Limited" : "⛔ Quota Exhausted / Rate Limited"
        items.append((.quotaExhausted, quotaExhaustedBadge, quotaExhaustedLabel, "Provider usage limit reached; turn halted"))

        let quotaRestoredBadge = EffectiveDisplayStatus.quotaRestored.badge(theme: theme)
        let quotaRestoredLabel = (theme == .funEmoji) ? "\(quotaRestoredBadge) Quota Restored / Ready Again" : "\(quotaRestoredBadge) [Quota Restored] Quota Recovered / Ready Again"
        items.append((.quotaRestored, quotaRestoredBadge, quotaRestoredLabel, "Provider recovered quota (>0% remaining after exhaustion); standby for prompt"))

        let idleBadge = EffectiveDisplayStatus.idle.badge(theme: theme)
        items.append((.idle, idleBadge, "\(idleBadge) Idle / Standby", "Agent process is running and standby for input"))

        let warnBadge = EffectiveDisplayStatus.monitorUnavailable.badge(theme: theme)
        items.append((.monitorUnavailable, warnBadge, "\(warnBadge) Monitor Not Connected", "The monitoring companion is not currently reporting. It may be disabled, missing, or temporarily unavailable."))

        let offBadge = EffectiveDisplayStatus.off.badge(theme: theme)
        items.append((.off, offBadge, "\(offBadge) App Closed / Process Terminated", "Agent process or browser tab is not running"))

        return items
    }

    public func scheduleTitleAndMenuUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let timeSinceLast = now.timeIntervalSince(self.lastRebuildTime)
            let minInterval: TimeInterval = 0.25 // 250ms rate-bound for spaced triggers

            if timeSinceLast >= minInterval {
                if self.pendingThrottledTimer != nil {
                    self.pendingThrottledTimer?.invalidate()
                    self.pendingThrottledTimer = nil
                    self.activePendingTimerCount = 0
                }
                self.performUpdateTitleAndMenu()
            } else {
                guard self.pendingThrottledTimer == nil else { return }
                let remaining = minInterval - timeSinceLast
                self.activePendingTimerCount = 1
                self.pendingThrottledTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    self?.pendingThrottledTimer = nil
                    self?.activePendingTimerCount = 0
                    self?.performUpdateTitleAndMenu()
                }
            }
        }
    }

    public func updateTitleAndMenu() {
        scheduleTitleAndMenuUpdate()
    }

    public func makeEmojiFunAttributedTitle(displayMode: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "[")
        let currentTheme = AgentStore.shared.currentTheme
        let overworkMins = AgentStore.shared.overworkThresholdMinutes

        if displayMode.lowercased() == "compact" {
            let topAgent = AgentStore.shared.getHighestPriorityAgent()
            if let top = topAgent, AgentStore.canonicalPriorityRank(for: top) >= 30 {
                let badge = top.effectiveDisplayStatus.badge(theme: currentTheme)
                if let icon = ProviderIconLoader.shared.getIcon(for: top.id) {
                    let attach = NSTextAttachment()
                    attach.image = icon
                    attach.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
                    result.append(NSAttributedString(attachment: attach))
                    result.append(NSAttributedString(string: " \(badge)"))
                } else {
                    let customCfg = ConfigManager.shared.getAgentConfig(for: top.id)
                    let tag = customCfg?.shortTag ?? top.id.shortTag
                    result.append(NSAttributedString(string: "\(tag)\(badge)"))
                }

                // Check extra count of same rank
                let allStates = AgentStore.shared.getAllStates()
                let monitored = AgentID.allCases.filter { ConfigManager.shared.isAgentMonitored($0) }
                let topRank = AgentStore.canonicalPriorityRank(for: top)
                let sameRankCount = monitored.filter {
                    let info = allStates[$0] ?? AgentInfo(id: $0)
                    return AgentStore.canonicalPriorityRank(for: info) == topRank
                }.count
                if sameRankCount > 1 {
                    result.append(NSAttributedString(string: " +\(sameRankCount - 1)"))
                }
            } else {
                let anyIdle = AgentID.allCases.filter { ConfigManager.shared.isAgentMonitored($0) }.contains {
                    let st = AgentStore.shared.getStatus(for: $0)
                    return st.status == .idle && st.effectiveDisplayStatus == .idle
                }
                result.append(NSAttributedString(string: anyIdle ? "⚪" : "⚫"))
            }
        } else {
            let monitored = AgentID.allCases.filter { ConfigManager.shared.isAgentMonitored($0) }
            let visibleAgents = monitored.filter { agent in
                let info = AgentStore.shared.getStatus(for: agent)
                return info.status != .off && info.effectiveDisplayStatus != .off
            }

            if visibleAgents.isEmpty {
                // Zero-width protection fallback when all monitored providers are closed
                result.append(NSAttributedString(string: "⚫"))
            } else {
                for (idx, agent) in visibleAgents.enumerated() {
                    if idx > 0 {
                        result.append(NSAttributedString(string: " | "))
                    }
                    let info = AgentStore.shared.getStatus(for: agent)
                    let thinkingDur: TimeInterval? = info.thinkingStartTime != nil ? Date().timeIntervalSince(info.thinkingStartTime!) : nil
                    let badge = info.effectiveDisplayStatus.badge(theme: currentTheme, thinkingDuration: thinkingDur, overworkThresholdMinutes: overworkMins)

                    if let icon = ProviderIconLoader.shared.getIcon(for: agent) {
                        let attach = NSTextAttachment()
                        attach.image = icon
                        attach.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
                        result.append(NSAttributedString(attachment: attach))
                        result.append(NSAttributedString(string: " \(badge)"))
                    } else {
                        let customCfg = ConfigManager.shared.getAgentConfig(for: agent)
                        let tag = customCfg?.shortTag ?? agent.shortTag
                        result.append(NSAttributedString(string: "\(tag):\(badge)"))
                    }
                }
            }
        }

        result.append(NSAttributedString(string: "]"))
        return result
    }

    public func performUpdateTitleAndMenu() {
        lastRebuildTime = Date()
        renderExecutionCount += 1
        onPerformUpdateTitleAndMenu?()

        guard let item = statusItem, let button = item.button else { return }

        let displayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        let currentTheme = AgentStore.shared.currentTheme

        if currentTheme == .funEmoji {
            let attr = makeEmojiFunAttributedTitle(displayMode: displayMode)
            button.attributedTitle = attr
        } else {
            if displayMode.lowercased() == "compact" {
                let compact = AgentStore.shared.compactSummary()
                button.title = "[\(compact)]"
            } else {
                let summary = AgentStore.shared.overallSummary()
                button.title = "[\(summary)]"
            }
        }

        let currentSignature = computeRenderSignature()
        if currentSignature == lastRenderedSignature {
            return // Suppress redundant menu rebuild when render-affecting state is identical
        }
        lastRenderedSignature = currentSignature

        rebuildMenu()
    }


    public func computeRenderSignature() -> String {
        let displayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        let summary = AgentStore.shared.overallSummary()
        let compact = AgentStore.shared.compactSummary()
        let theme = AgentStore.shared.currentTheme.rawValue
        let overwork = AgentStore.shared.overworkThresholdMinutes

        let cfg = ConfigManager.shared.config
        let notifyEnabled = cfg.notificationsEnabled ?? true
        let soundEnabled = NotificationManager.shared.soundEnabled
        let doneSound = cfg.doneSoundName ?? "Glass"
        let attentionSound = cfg.attentionSoundName ?? "Basso"
        let sleepMode = "\(SleepManager.shared.mode.rawValue):\(SleepManager.shared.isAssertionActive):\(SleepManager.shared.currentReason ?? "")"
        let closedLid = "\(SleepManager.shared.isClosedLidModeEnabled):\(SleepManager.shared.isDisableSleepActive)"
        let refreshingTag = isRefreshingUsage
        let axTrusted = AXIsProcessTrusted()
        let disabledAgents = (ConfigManager.shared.config.disabledAgents ?? []).sorted().joined(separator: ",")
        let armedWatchTag = OneShotSwitchManager.shared.armedTarget != nil ? "\(OneShotSwitchManager.shared.armedTarget!.provider.rawValue):\(OneShotSwitchManager.shared.armedTarget!.sessionId ?? "")" : "none"

        var sessionsStr = ""
        for s in AgentStore.shared.getAllSessions() {
            sessionsStr += "\(s.provider.rawValue):\(s.sessionId):\(s.status.rawValue):\(s.title); "
        }
        var stateDetails = ""
        for agent in AgentID.allCases {
            let info = AgentStore.shared.getStatus(for: agent)
            let usage = AgentUsageStore.shared.getUsage(for: agent)

            var openTabsStr = ""
            for tab in info.openTabs {
                openTabsStr.append("\(tab.title):\(tab.url):\(tab.status):\(tab.active ?? false);")
            }

            var famStr = ""
            if let families = usage?.modelFamilies {
                for f in families {
                    famStr.append("\(f.name):\(f.sessionLimitPercent ?? 0):\(f.weeklyLimitPercent ?? 0):\(f.isPercentUsed):\(f.isExhausted);")
                }
            }

            stateDetails += "\(agent.rawValue):\(info.status.rawValue):\(info.availability.rawValue):\(info.effectiveDisplayStatus.rawValue):\(usage?.availability.rawValue ?? ""):[\(famStr)]:\(info.detail ?? ""):\(info.activeSessionCount):\(info.sessionTitle ?? ""):\(info.webLink ?? ""):[\(openTabsStr)]:\(usage?.freshness ?? ""):\(usage?.sessionLimitPercent ?? 0):\(usage?.weeklyLimitPercent ?? 0):\(usage?.sessionResetText ?? ""):\(usage?.weeklyResetText ?? ""):\(usage?.isLiveSource ?? false):\(usage?.isQuotaExhausted ?? false):\(usage?.lastSuccessfulRefresh?.timeIntervalSince1970 ?? 0);"
        }
        let tgEnabled = cfg.isTelegramEnabled ?? true
        let tgConfigured = EnvConfigLoader.shared.getTelegramConfig().isConfigured
        let tgLastTest = TelegramBridge.shared.lastDeliveryResult?.safeSummary ?? "none"
        let tgThreshold = cfg.telegramDoneThresholdMinutes ?? 5
        let tgQuotaAlerts = cfg.isTelegramQuotaAlertsEnabled ?? true
        let netConnected = NetworkHealthMonitor.shared.isConnected
        let badgesSig = "\(cfg.statusBadges.done.funEmoji):\(cfg.statusBadges.working.funEmoji):\(cfg.statusBadges.blocked.funEmoji):\(cfg.statusBadges.overworking?.funEmoji ?? ""):\(cfg.statusBadges.idle.funEmoji):\(cfg.statusBadges.off.funEmoji):\(cfg.statusBadges.quotaDepleted?.funEmoji ?? ""):\(cfg.statusBadges.quotaRestored?.funEmoji ?? ""):\(cfg.statusBadges.monitorUnavailable?.funEmoji ?? "")"

        return "\(displayMode)|\(summary)|\(compact)|\(theme)|\(overwork)|\(notifyEnabled)|\(soundEnabled)|\(doneSound)|\(attentionSound)|\(sleepMode)|\(closedLid)|\(refreshingTag)|\(axTrusted)|\(disabledAgents)|\(armedWatchTag)|\(tgEnabled):\(tgConfigured):\(tgLastTest):\(tgThreshold):\(tgQuotaAlerts)|\(netConnected)|\(badgesSig)|\(sessionsStr)|\(stateDetails)"
    }

    // Compact Block Progress Bar Generator (e.g. [■■■■□□□□□□])
    private func makeCompactBar(percent: Double, totalBlocks: Int = 10) -> String {
        let clamped = max(0.0, min(100.0, percent))
        let filledCount = Int(round((clamped / 100.0) * Double(totalBlocks)))
        let emptyCount = max(0, totalBlocks - filledCount)

        let filled = String(repeating: "■", count: filledCount)
        let empty = String(repeating: "□", count: emptyCount)
        return "[\(filled)\(empty)]"
    }

    public func makeProviderFreshnessTag(usage: AgentUsageData?) -> String? {
        guard let usage = usage, (usage.weeklyLimitPercent != nil || usage.sessionLimitPercent != nil || !usage.modelFamilies.isEmpty) else {
            return "Quota unavailable"
        }
        if usage.isLiveSource {
            return nil
        }
        let ts = usage.lastSuccessfulRefresh ?? usage.lastUpdated
        let timeStr = ts.relativeString()
        return "last known · \(timeStr)"
    }

    public func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()

        let currentTheme = AgentStore.shared.currentTheme
        let overworkMins = AgentStore.shared.overworkThresholdMinutes

        // 1. Header & Color Legend Submenu
        let headerItem = NSMenuItem(title: "AgentBridge — 1-Click Priority Monitor", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if !NetworkHealthMonitor.shared.isConnected {
            let netItem = NSMenuItem(title: "🌐 Connection Unavailable", action: nil, keyEquivalent: "")
            netItem.isEnabled = false
            menu.addItem(netItem)
        }

        // Status Legend Submenu (Theme-Aware)
        let legendSubmenu = NSMenu()

        let agentsHeading = NSMenuItem(title: "Agents & Icons:", action: nil, keyEquivalent: "")
        agentsHeading.isEnabled = false
        legendSubmenu.addItem(agentsHeading)

        for agent in AgentID.allCases {
            let agItem = NSMenuItem(title: "  \(agent.displayName)", action: nil, keyEquivalent: "")
            if let icon = ProviderIconLoader.shared.getIcon(for: agent) {
                agItem.image = icon
            }
            agItem.isEnabled = false
            legendSubmenu.addItem(agItem)
        }

        legendSubmenu.addItem(NSMenuItem.separator())

        let themeHeading = NSMenuItem(title: "Current Style: \(currentTheme == .funEmoji ? "Emoji" : "Classic Traffic Light")", action: nil, keyEquivalent: "")
        themeHeading.isEnabled = false
        legendSubmenu.addItem(themeHeading)
        legendSubmenu.addItem(NSMenuItem.separator())

        let legendItems = MenuBarManager.getStatusLegendItems(theme: currentTheme, overworkMinutes: overworkMins)
        for item in legendItems {
            let legItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            legItem.image = cachedDisplayDotImage(for: item.status)
            legItem.toolTip = item.desc
            legItem.isEnabled = false
            legendSubmenu.addItem(legItem)
        }

        let legendItem = NSMenuItem(title: "Status Meaning & Color Legend...", action: nil, keyEquivalent: "")
        legendItem.submenu = legendSubmenu
        menu.addItem(legendItem)

        menu.addItem(NSMenuItem.separator())

        // Top Priority Action (1-Click Focus/Switch)
        if let topAgent = AgentStore.shared.getHighestPriorityAgent() {
            let sessionTag = (topAgent.sessionTitle?.isEmpty == false) ? " (\(topAgent.sessionTitle!))" : ""
            let actionText: String
            if topAgent.status == .blocked {
                actionText = "ATTENTION: Switch to \(topAgent.id.displayName)\(sessionTag)"
            } else if topAgent.status == .done {
                actionText = "JUMP TO NEW OUTPUT: \(topAgent.id.displayName)\(sessionTag)"
            } else {
                actionText = "Jump to Active: \(topAgent.id.displayName)\(sessionTag)"
            }

            let topActionItem = NSMenuItem(title: actionText, action: #selector(topActionClicked(_:)), keyEquivalent: "j")
            topActionItem.target = self
            topActionItem.representedObject = topAgent
            menu.addItem(topActionItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 2. Direct 1-Click Agent & Session Rows (Filtered by Monitored Agents)
        let allStates = AgentStore.shared.getAllStates()
        for agent in AgentID.allCases {
            guard ConfigManager.shared.isAgentMonitored(agent) else { continue }
            let info = allStates[agent] ?? AgentInfo(id: agent)
            let providerSessions = AgentStore.shared.getSessions(for: agent)

            let effAvail = AgentUsageStore.shared.getUsage(for: agent)?.availability ?? info.availability
            let isQuotaExhausted = (effAvail == .quotaExhausted) || (AgentUsageStore.shared.getUsage(for: agent)?.isQuotaExhausted == true)
            let isUnavailable = (info.detail?.contains("Monitoring unavailable") == true || info.detail?.contains("Experimental") == true)
            let statusLabel: String
            if isQuotaExhausted {
                statusLabel = "Quota Exhausted"
            } else if isUnavailable {
                statusLabel = "Monitoring unavailable / Experimental"
            } else {
                statusLabel = info.status.statusTitle
            }

            var durationTag = ""
            if isQuotaExhausted {
                if agent == .claude {
                    let pct = Int(AgentUsageStore.shared.getUsage(for: .claude)?.sessionRemainingPercent ?? 0.0)
                    durationTag = " [5-hour: \(pct)% left]"
                } else {
                    durationTag = " [\(info.lastUpdated.relativeString())]"
                }
            } else if info.status == .working, let start = info.thinkingStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                durationTag = mins > 0 ? " [thinking \(mins)m \(secs)s]" : " [thinking \(secs)s]"
            } else if info.status == .done, let dur = info.lastDurationSeconds {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                durationTag = mins > 0 ? " [took \(mins)m \(secs)s]" : " [took \(secs)s]"
            } else {
                durationTag = " [\(info.lastUpdated.relativeString())]"
            }

            let sessionStr = providerSessions.count > 1 ? " (\(providerSessions.count) sessions)" : ""
            let rawTitle = info.sessionTitle ?? ""
            let nameTag = (!rawTitle.isEmpty) ? " — \(rawTitle.prefix(25))\(rawTitle.count > 25 ? "..." : "")" : ""

            let thinkingDur: TimeInterval? = info.thinkingStartTime != nil ? Date().timeIntervalSince(info.thinkingStartTime!) : nil
            let displayStatus = info.effectiveDisplayStatus
            let badge = displayStatus.badge(theme: currentTheme, thinkingDuration: thinkingDur, overworkThresholdMinutes: overworkMins)
            let displayStatusLabel: String
            if displayStatus == .quotaExhausted {
                displayStatusLabel = "Quota Exhausted"
            } else if displayStatus == .quotaRestored {
                displayStatusLabel = "Quota Restored"
            } else {
                displayStatusLabel = statusLabel
            }
            let title: String
            if displayStatus == .monitorUnavailable {
                title = "⚠️ \(agent.displayName) — Monitor Unavailable"
            } else if displayStatus == .quotaRestored {
                title = "\(badge) \(agent.displayName)\(nameTag)\(sessionStr) [Quota Restored] [Idle]"
            } else {
                title = "\(badge) \(agent.displayName)\(nameTag)\(sessionStr) [\(displayStatusLabel)]\(durationTag)"
            }

            let item = NSMenuItem(title: title, action: #selector(agentItemClicked(_:)), keyEquivalent: "")
            item.image = cachedDisplayDotImage(for: displayStatus)
            item.target = self
            item.representedObject = agent

            // Submenu for Detailed Info & Tracked Sessions
            let submenu = NSMenu()

            if agent == .chatgpt {
                if displayStatus == .monitorUnavailable {
                    let warnItem = NSMenuItem(title: "⚠️ Web Monitor Not Connected", action: nil, keyEquivalent: "")
                    warnItem.isEnabled = false
                    submenu.addItem(warnItem)

                    let descItem = NSMenuItem(title: "   Chrome extension is not reporting", action: nil, keyEquivalent: "")
                    descItem.isEnabled = false
                    submenu.addItem(descItem)

                    let openExtItem = NSMenuItem(title: "   Open Chrome Extensions…", action: #selector(openChromeExtensionsClicked(_:)), keyEquivalent: "")
                    openExtItem.target = self
                    submenu.addItem(openExtItem)

                    submenu.addItem(NSMenuItem.separator())
                }

                if !info.openTabs.isEmpty {
                    let tabsHeader = NSMenuItem(title: "Open ChatGPT Chrome Tabs (\(info.openTabs.count)):", action: nil, keyEquivalent: "")
                    tabsHeader.isEnabled = false
                    submenu.addItem(tabsHeader)

                    for tab in info.openTabs {
                        let tabStatus = AgentStatus(rawValue: tab.status) ?? .idle
                        let tabStatusDot = tabStatus.statusDot(theme: currentTheme)
                        let activeTag = tab.active == true ? " [Active Tab]" : ""
                        let tabItem = NSMenuItem(title: "  \(tabStatusDot) \(tab.title)\(activeTag)", action: #selector(openWebLinkClicked(_:)), keyEquivalent: "")
                        tabItem.image = cachedDisplayDotImage(for: EffectiveDisplayStatus.from(lifecycle: tab.status, availability: effAvail))
                        tabItem.target = self
                        tabItem.representedObject = ["url": tab.url, "tabId": tab.tabId as Any]
                        submenu.addItem(tabItem)

                        let isTabArmed = OneShotSwitchManager.shared.isArmed(provider: .chatgpt, sessionId: nil, targetTabId: tab.tabId)
                        let tabSwitchItem = NSMenuItem(title: "    Auto-Switch When Ready", action: #selector(toggleOneShotSwitchClicked(_:)), keyEquivalent: "")
                        tabSwitchItem.target = self
                        tabSwitchItem.state = isTabArmed ? .on : .off
                        tabSwitchItem.representedObject = ["agent": AgentID.chatgpt, "tabId": tab.tabId as Any, "url": tab.url as Any]
                        submenu.addItem(tabSwitchItem)
                    }
                } else if displayStatus != .monitorUnavailable {
                    let noTabsItem = NSMenuItem(title: "No open ChatGPT tabs in Chrome", action: nil, keyEquivalent: "")
                    noTabsItem.isEnabled = false
                    submenu.addItem(noTabsItem)
                }

                submenu.addItem(NSMenuItem.separator())
                let timeItem = NSMenuItem(title: "Last Update: \(info.lastUpdated.relativeString())", action: nil, keyEquivalent: "")
                timeItem.isEnabled = false
                submenu.addItem(timeItem)
            } else {
                if displayStatus == .monitorUnavailable {
                    let warnItem = NSMenuItem(title: "⚠️ \(agent.displayName) Monitor Unavailable", action: nil, keyEquivalent: "")
                    warnItem.isEnabled = false
                    submenu.addItem(warnItem)

                    let desc: String
                    if agent == .codex {
                        desc = "   Local state database unavailable or unparseable"
                    } else {
                        desc = "   Monitoring source is unavailable"
                    }
                    let descItem = NSMenuItem(title: desc, action: nil, keyEquivalent: "")
                    descItem.isEnabled = false
                    submenu.addItem(descItem)

                    submenu.addItem(NSMenuItem.separator())
                }

                if let sessionTitle = info.sessionTitle, !sessionTitle.isEmpty {
                    let sItem = NSMenuItem(title: "Active Session: \(sessionTitle)", action: nil, keyEquivalent: "")
                    sItem.isEnabled = false
                    submenu.addItem(sItem)
                }

                if !providerSessions.isEmpty {
                    let trackedHeader = NSMenuItem(title: "Tracked Workspace Sessions (\(providerSessions.count)):", action: nil, keyEquivalent: "")
                    trackedHeader.isEnabled = false
                    submenu.addItem(trackedHeader)

                    for s in providerSessions {
                        let sBadge = s.status.statusDot(theme: currentTheme)
                        let subItem = NSMenuItem(title: "  \(sBadge) [\(s.status.statusTitle)] \(s.title)", action: nil, keyEquivalent: "")
                        subItem.image = cachedDisplayDotImage(for: EffectiveDisplayStatus.from(lifecycle: s.status, availability: effAvail))
                        subItem.isEnabled = false
                        submenu.addItem(subItem)
                    }
                }

                let detailItem = NSMenuItem(title: "Detail: \(info.detail ?? "No active task")", action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                submenu.addItem(detailItem)

                let timeItem = NSMenuItem(title: "Last Update: \(info.lastUpdated.relativeString())", action: nil, keyEquivalent: "")
                timeItem.isEnabled = false
                submenu.addItem(timeItem)

                if info.status != .off {
                    submenu.addItem(NSMenuItem.separator())
                    let currentSessionId = providerSessions.first?.sessionId
                    let isArmed = OneShotSwitchManager.shared.isArmed(provider: agent, sessionId: currentSessionId, targetTabId: info.targetTabId)
                    let switchItem = NSMenuItem(title: "Auto-Switch When Ready", action: #selector(toggleOneShotSwitchClicked(_:)), keyEquivalent: "")
                    switchItem.target = self
                    switchItem.state = isArmed ? .on : .off
                    switchItem.representedObject = ["agent": agent, "sessionId": currentSessionId as Any, "tabId": info.targetTabId as Any, "webLink": info.webLink as Any]
                    submenu.addItem(switchItem)
                }
            }

            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 3. Provider Quota & Limits Section (Live disk / source)
        let quotaHeader = NSMenuItem(title: "Provider Usage Limits & Reset Windows:", action: nil, keyEquivalent: "")
        quotaHeader.isEnabled = false
        menu.addItem(quotaHeader)

        let allUsage = AgentUsageStore.shared.getAllUsage()

        // 3A. Claude Code Usage Rows
        if ConfigManager.shared.isAgentMonitored(.claude), let claudeUsage = allUsage[.claude] {
            let hdr = NSMenuItem(title: "  Claude Code", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            let isClaudeWeeklyZero = (claudeUsage.weeklyRemainingPercent == 0)
            if !isClaudeWeeklyZero, let sRemaining = claudeUsage.sessionRemainingPercent {
                let sBar = makeCompactBar(percent: sRemaining)
                let sReset = claudeUsage.sessionResetText ?? ""
                let resetTag = sReset.isEmpty ? "" : " · \(sReset)"
                let row1 = NSMenuItem(title: "     5-Hour:  \(sBar) \(Int(sRemaining))% left\(resetTag)", action: nil, keyEquivalent: "")
                row1.isEnabled = false
                menu.addItem(row1)
            }

            if let wRemaining = claudeUsage.weeklyRemainingPercent {
                let wBar = makeCompactBar(percent: wRemaining)
                let wReset = claudeUsage.weeklyResetText ?? ""
                let resetTag = wReset.isEmpty ? "" : " · \(wReset)"
                let row2 = NSMenuItem(title: "     Weekly:  \(wBar) \(Int(wRemaining))% left\(resetTag)", action: nil, keyEquivalent: "")
                row2.isEnabled = false
                menu.addItem(row2)
            }

            if let freshnessText = makeProviderFreshnessTag(usage: claudeUsage) {
                let freshRow = NSMenuItem(title: "     · \(freshnessText)", action: nil, keyEquivalent: "")
                freshRow.isEnabled = false
                menu.addItem(freshRow)
            }
        }

        // 3B. Antigravity Usage Rows
        if ConfigManager.shared.isAgentMonitored(.antigravity), let agyUsage = allUsage[.antigravity] {
            let hdr = NSMenuItem(title: "  Antigravity", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if !agyUsage.modelFamilies.isEmpty {
                for family in agyUsage.modelFamilies {
                    let fExhaustedTag = family.isExhausted ? " ⦸" : ""
                    let fHdr = NSMenuItem(title: "     \(family.name)\(fExhaustedTag):", action: nil, keyEquivalent: "")
                    fHdr.isEnabled = false
                    menu.addItem(fHdr)

                    let isFamilyWeeklyZero = (family.weeklyRemainingPercent == 0)
                    if !isFamilyWeeklyZero, let sRemaining = family.sessionRemainingPercent {
                        let bar = makeCompactBar(percent: sRemaining)
                        let resetTag = (family.sessionResetText?.isEmpty == false) ? " · \(family.sessionResetText!)" : ""
                        let row = NSMenuItem(title: "       5-Hour: \(bar) \(Int(sRemaining))% left\(resetTag)", action: nil, keyEquivalent: "")
                        row.isEnabled = false
                        menu.addItem(row)
                    }

                    if let wRemaining = family.weeklyRemainingPercent {
                        let bar = makeCompactBar(percent: wRemaining)
                        let resetTag = (family.weeklyResetText?.isEmpty == false) ? " · \(family.weeklyResetText!)" : ""
                        let row = NSMenuItem(title: "       Weekly: \(bar) \(Int(wRemaining))% left\(resetTag)", action: nil, keyEquivalent: "")
                        row.isEnabled = false
                        menu.addItem(row)
                    }
                }
                if let freshnessText = makeProviderFreshnessTag(usage: agyUsage) {
                    let freshRow = NSMenuItem(title: "     · \(freshnessText)", action: nil, keyEquivalent: "")
                    freshRow.isEnabled = false
                    menu.addItem(freshRow)
                }
            } else {
                let unavailRow = NSMenuItem(title: "     Quota: [Live quota source unavailable]", action: nil, keyEquivalent: "")
                unavailRow.isEnabled = false
                menu.addItem(unavailRow)
            }
        }

        // 3C. Codex Desktop Usage Rows
        if ConfigManager.shared.isAgentMonitored(.codex), let cdxUsage = allUsage[.codex] {
            let hdr = NSMenuItem(title: "  Codex Desktop", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if let wRemaining = cdxUsage.weeklyRemainingPercent {
                let bar = makeCompactBar(percent: wRemaining)
                let resetTag = cdxUsage.weeklyResetText ?? ""
                let resetPrefix = resetTag.isEmpty ? "" : " · \(resetTag)"
                let row = NSMenuItem(title: "     Weekly:  \(bar) \(Int(wRemaining))% left\(resetPrefix)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)

                if let freshnessText = makeProviderFreshnessTag(usage: cdxUsage) {
                    let freshRow = NSMenuItem(title: "     · \(freshnessText)", action: nil, keyEquivalent: "")
                    freshRow.isEnabled = false
                    menu.addItem(freshRow)
                }
            } else {
                let unavailRow = NSMenuItem(title: "     Quota: [Live quota source unavailable]", action: nil, keyEquivalent: "")
                unavailRow.isEnabled = false
                menu.addItem(unavailRow)
            }
        }

        // 3D. GitHub Copilot Usage Rows
        if ConfigManager.shared.isAgentMonitored(.copilot), let copilotUsage = allUsage[.copilot] {
            let hdr = NSMenuItem(title: "  GitHub Copilot", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if let sRemaining = copilotUsage.sessionRemainingPercent {
                let bar = makeCompactBar(percent: sRemaining)
                let resetTag = copilotUsage.sessionResetText ?? ""
                let resetPrefix = resetTag.isEmpty ? "" : " · \(resetTag)"
                let row = NSMenuItem(title: "     Chat:    \(bar) \(Int(sRemaining))% left\(resetPrefix)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)

                if let freshnessText = makeProviderFreshnessTag(usage: copilotUsage) {
                    let freshRow = NSMenuItem(title: "     · \(freshnessText)", action: nil, keyEquivalent: "")
                    freshRow.isEnabled = false
                    menu.addItem(freshRow)
                }
            } else {
                let unavailRow = NSMenuItem(title: "     Quota: [Live quota source unavailable]", action: nil, keyEquivalent: "")
                unavailRow.isEnabled = false
                menu.addItem(unavailRow)
            }
        }

        // 3E. Interactive Refresh Button
        let refreshUsageTitle: String
        if isRefreshingUsage {
            refreshUsageTitle = "  🔄 Refreshing Usage Limits..."
        } else {
            refreshUsageTitle = "  Refresh Usage Limits"
        }
        let refreshUsageItem = NSMenuItem(title: refreshUsageTitle, action: #selector(refreshUsageClicked), keyEquivalent: "r")
        refreshUsageItem.target = self
        menu.addItem(refreshUsageItem)

        menu.addItem(NSMenuItem.separator())

        // Operational Controls: Smart Keep-Awake (First-Level Menu)
        let currentSleepMode = SleepManager.shared.mode
        let sleepStateTag = SleepManager.shared.isAssertionActive ? " [☕ ACTIVE]" : " [💤 IDLE]"
        let sleepTitle: String
        switch currentSleepMode {
        case .smartAuto: sleepTitle = "Smart Keep-Awake: Smart Auto\(sleepStateTag)"
        case .alwaysOn: sleepTitle = "Smart Keep-Awake: Always Awake"
        case .timer1h: sleepTitle = "Smart Keep-Awake: 1 Hour"
        case .timer3h: sleepTitle = "Smart Keep-Awake: 3 Hours"
        case .disabled: sleepTitle = "Smart Keep-Awake: Off"
        }
        let sleepMainItem = NSMenuItem(title: sleepTitle, action: nil, keyEquivalent: "")
        let sleepSubmenu = NSMenu()
        for modeOption in AntiSleepMode.allCases {
            var optionTitle = modeOption.displayName
            if modeOption == .smartAuto && currentSleepMode == .smartAuto {
                if SleepManager.shared.isAssertionActive {
                    let reasonStr = SleepManager.shared.currentReason ?? "Active"
                    optionTitle = "Smart Auto — ☕ \(reasonStr)"
                } else {
                    optionTitle = "Smart Auto — 💤 Idle (Releasing Sleep)"
                }
            }
            let item = NSMenuItem(title: optionTitle, action: #selector(selectAntiSleepModeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = modeOption
            if modeOption == currentSleepMode {
                item.state = .on
            }
            sleepSubmenu.addItem(item)
        }

        // Closed-Lid / Clamshell Prevention (pmset) Submenu Item
        sleepSubmenu.addItem(NSMenuItem.separator())
        let isClosedLid = SleepManager.shared.isClosedLidModeEnabled
        let privStatus = SleepManager.checkPrivilegeStatus()
        let privTag = privStatus.hasPrivilege ? "" : " [Requires Sudoers Setup]"
        let closedLidTitle = isClosedLid ? "Closed-Lid / Clamshell Mode (pmset): ON\(privTag)" : "Closed-Lid / Clamshell Mode (pmset): OFF\(privTag)"
        let closedLidItem = NSMenuItem(title: closedLidTitle, action: #selector(toggleClosedLidModeClicked), keyEquivalent: "")
        closedLidItem.target = self
        if isClosedLid {
            closedLidItem.state = .on
        }
        sleepSubmenu.addItem(closedLidItem)
        sleepMainItem.submenu = sleepSubmenu
        menu.addItem(sleepMainItem)

        // Operational Controls: Telegram Alerts (Root Menu Sibling of Smart Keep-Awake and Settings)
        let tgConfig = EnvConfigLoader.shared.getTelegramConfig()
        let isTelegramEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        let tgTitle: String
        if !tgConfig.isConfigured {
            tgTitle = "Telegram Alerts: Not Configured"
        } else if isTelegramEnabled {
            tgTitle = "Telegram Alerts: On"
        } else {
            tgTitle = "Telegram Alerts: Off"
        }
        let telegramItem = NSMenuItem(title: tgTitle, action: nil, keyEquivalent: "")
        let telegramSubmenu = NSMenu()

        // 1. Enable / Disable Toggle
        let enableItem = NSMenuItem(title: "Enabled", action: tgConfig.isConfigured ? #selector(toggleTelegramAlertsClicked) : nil, keyEquivalent: "")
        enableItem.target = self
        enableItem.state = (isTelegramEnabled && tgConfig.isConfigured) ? .on : .off
        enableItem.isEnabled = tgConfig.isConfigured
        telegramSubmenu.addItem(enableItem)
        telegramSubmenu.addItem(NSMenuItem.separator())

        // 2. Done Notifications Threshold Submenu
        let currentDoneThreshold = ConfigManager.shared.config.telegramDoneThresholdMinutes ?? 5
        let doneThresholdTitle = currentDoneThreshold == 0 ? "Done Notifications: Off" : "Done Notifications: \(currentDoneThreshold) min+"
        let doneThresholdItem = NSMenuItem(title: doneThresholdTitle, action: nil, keyEquivalent: "")
        let doneThresholdSubmenu = NSMenu()
        let availableThresholdOptions: [(Int, String)] = [
            (0, "Off (Per-Session Override Only)"),
            (1, "1 min+"),
            (3, "3 min+"),
            (5, "5 min+ (Default)"),
            (10, "10 min+"),
            (15, "15 min+")
        ]
        for (mins, label) in availableThresholdOptions {
            let item = NSMenuItem(title: label, action: #selector(selectTelegramDoneThresholdClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mins
            if mins == currentDoneThreshold {
                item.state = .on
            }
            doneThresholdSubmenu.addItem(item)
        }
        doneThresholdItem.submenu = doneThresholdSubmenu
        telegramSubmenu.addItem(doneThresholdItem)

        // 3. Notify Specific Sessions Submenu
        let specificSessionsItem = NSMenuItem(title: "Notify Specific Sessions", action: nil, keyEquivalent: "")
        let specificSessionsMenu = NSMenu()
        var allActiveTopSessions: [AgentSessionInfo] = []
        for agent in AgentID.allCases {
            guard ConfigManager.shared.isAgentMonitored(agent) else { continue }
            let sessList = AgentStore.shared.getSessions(for: agent)
            allActiveTopSessions.append(contentsOf: sessList)
        }

        if allActiveTopSessions.isEmpty {
            let noSessItem = NSMenuItem(title: "No Active Sessions", action: nil, keyEquivalent: "")
            noSessItem.isEnabled = false
            specificSessionsMenu.addItem(noSessItem)
        } else {
            for session in allActiveTopSessions {
                let isArmed = TelegramBridge.shared.isNotifyMeOverrideActive(provider: session.provider, sessionId: session.sessionId)
                let itemTitle = "\(session.provider.displayName) — \(session.title)"
                let sItem = NSMenuItem(title: itemTitle, action: #selector(toggleOneShotTelegramNotifyClicked(_:)), keyEquivalent: "")
                sItem.target = self
                sItem.representedObject = ["agent": session.provider, "sessionId": session.sessionId, "turnId": session.turnId as Any]
                sItem.state = isArmed ? .on : .off
                specificSessionsMenu.addItem(sItem)
            }
        }
        specificSessionsItem.submenu = specificSessionsMenu
        telegramSubmenu.addItem(specificSessionsItem)

        telegramSubmenu.addItem(NSMenuItem.separator())

        // 4. Quota Exhausted / Restored Toggle
        let isQuotaAlerts = ConfigManager.shared.config.isTelegramQuotaAlertsEnabled ?? true
        let quotaToggleItem = NSMenuItem(title: "Quota Exhausted / Restored", action: #selector(toggleTelegramQuotaAlertsClicked), keyEquivalent: "")
        quotaToggleItem.target = self
        quotaToggleItem.state = isQuotaAlerts ? .on : .off
        telegramSubmenu.addItem(quotaToggleItem)

        telegramSubmenu.addItem(NSMenuItem.separator())

        // 5. High-Priority Alerts (Always On)
        let highPriorityHeading = NSMenuItem(title: "High-Priority Alerts", action: nil, keyEquivalent: "")
        highPriorityHeading.isEnabled = false
        telegramSubmenu.addItem(highPriorityHeading)

        let needsYouItem = NSMenuItem(title: "  Needs You: Always", action: nil, keyEquivalent: "")
        needsYouItem.state = .on
        needsYouItem.isEnabled = false
        telegramSubmenu.addItem(needsYouItem)

        let monitorFailItem = NSMenuItem(title: "  Monitor / Connection Failure: Always", action: nil, keyEquivalent: "")
        monitorFailItem.state = .on
        monitorFailItem.isEnabled = false
        telegramSubmenu.addItem(monitorFailItem)

        // 6. Test Notification
        if tgConfig.isConfigured {
            telegramSubmenu.addItem(NSMenuItem.separator())
            let testItem = NSMenuItem(title: "Send Test Notification", action: #selector(sendTelegramTestNotificationClicked), keyEquivalent: "")
            testItem.target = self
            telegramSubmenu.addItem(testItem)
        }

        telegramItem.submenu = telegramSubmenu
        menu.addItem(telegramItem)

        // 4. Consolidated Settings & Preferences Submenu
        let settingsItem = NSMenuItem(title: "Settings & Preferences...", action: nil, keyEquivalent: ",")
        let settingsSubmenu = NSMenu()

        // 4A. Monitored Agents Submenu
        let monitoredAgentsItem = NSMenuItem(title: "Monitored Agents", action: nil, keyEquivalent: "")
        let monitoredAgentsSubmenu = NSMenu()
        for agent in AgentID.allCases {
            let isMonitored = ConfigManager.shared.isAgentMonitored(agent)
            let agentItem = NSMenuItem(title: agent.displayName, action: #selector(toggleAgentMonitoredClicked(_:)), keyEquivalent: "")
            agentItem.target = self
            agentItem.representedObject = agent
            agentItem.state = isMonitored ? .on : .off
            monitoredAgentsSubmenu.addItem(agentItem)
        }
        monitoredAgentsItem.submenu = monitoredAgentsSubmenu
        settingsSubmenu.addItem(monitoredAgentsItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // 4B. Overworking Threshold Submenu (Flattened)
        let overworkThresholdItem = NSMenuItem(title: "Overworking Threshold: \(overworkMins) min", action: nil, keyEquivalent: "")
        let overworkSubmenu = NSMenu()
        let availableThresholds = [5, 10, 15, 20, 30]
        for mins in availableThresholds {
            let item = NSMenuItem(title: "\(mins) min", action: #selector(selectOverworkThresholdClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mins
            if mins == overworkMins {
                item.state = .on
            }
            overworkSubmenu.addItem(item)
        }
        overworkThresholdItem.submenu = overworkSubmenu
        settingsSubmenu.addItem(overworkThresholdItem)

        // 4C. Alerts Submenu
        let alertsItem = NSMenuItem(title: "Alerts", action: nil, keyEquivalent: "")
        let alertsSubmenu = NSMenu()

        // macOS Pop-up Notifications
        let isNotifyEnabled = ConfigManager.shared.config.notificationsEnabled ?? true
        let notifyTitle = isNotifyEnabled ? "Pop-up Notifications: On" : "Pop-up Notifications: Off"
        let notifyToggleItem = NSMenuItem(title: notifyTitle, action: #selector(toggleNotificationsClicked), keyEquivalent: "")
        notifyToggleItem.target = self
        notifyToggleItem.state = isNotifyEnabled ? .on : .off
        alertsSubmenu.addItem(notifyToggleItem)

        // Completion Sound Selector Submenu
        let currentDoneSound = ConfigManager.shared.config.doneSoundName ?? "Glass"
        let doneSoundItem = NSMenuItem(title: "Completion Sound: \(currentDoneSound)", action: nil, keyEquivalent: "")
        let doneSoundSubmenu = NSMenu()
        let availableDoneSounds = ["Mute (No Sound)", "Glass", "Tink", "Pop", "Hero", "Purr", "Blow", "Bottle"]
        for soundName in availableDoneSounds {
            let item = NSMenuItem(title: soundName, action: #selector(selectDoneSoundClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = soundName
            if soundName == currentDoneSound {
                item.state = .on
            }
            doneSoundSubmenu.addItem(item)
        }
        doneSoundItem.submenu = doneSoundSubmenu
        alertsSubmenu.addItem(doneSoundItem)

        // Attention Required Sound Selector Submenu
        let currentAttentionSound = ConfigManager.shared.config.attentionSoundName ?? "Basso"
        let attentionSoundItem = NSMenuItem(title: "Attention Sound: \(currentAttentionSound)", action: nil, keyEquivalent: "")
        let attentionSoundSubmenu = NSMenu()
        let availableAttentionSounds = ["Mute (No Sound)", "Basso", "Sosumi", "Ping", "Funk", "Submarine", "Frog", "Morse"]
        for soundName in availableAttentionSounds {
            let item = NSMenuItem(title: soundName, action: #selector(selectAttentionSoundClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = soundName
            if soundName == currentAttentionSound {
                item.state = .on
            }
            attentionSoundSubmenu.addItem(item)
        }
        attentionSoundItem.submenu = attentionSoundSubmenu
        alertsSubmenu.addItem(attentionSoundItem)

        alertsItem.submenu = alertsSubmenu
        settingsSubmenu.addItem(alertsItem)

        // 4D. Appearance Submenu
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceSubmenu = NSMenu()

        // Menu Bar View (Detailed vs Compact)
        let currentDisplayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        let isDetailedView = currentDisplayMode.lowercased() != "compact"
        let viewMenuItem = NSMenuItem(title: "Menu Bar View", action: nil, keyEquivalent: "")
        let viewSubmenu = NSMenu()

        let detailedItem = NSMenuItem(title: "Detailed View", action: #selector(setMenuBarModeDetailedClicked), keyEquivalent: "")
        detailedItem.target = self
        detailedItem.state = isDetailedView ? .on : .off
        viewSubmenu.addItem(detailedItem)

        let compactItem = NSMenuItem(title: "Compact View", action: #selector(setMenuBarModeCompactClicked), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = !isDetailedView ? .on : .off
        viewSubmenu.addItem(compactItem)

        viewMenuItem.submenu = viewSubmenu
        appearanceSubmenu.addItem(viewMenuItem)

        // Status Style Submenu
        let styleTitle = currentTheme == .funEmoji ? "Status Style: Emoji" : "Status Style: Classic Traffic Light"
        let styleMenuItem = NSMenuItem(title: styleTitle, action: nil, keyEquivalent: "")
        let styleSubmenu = NSMenu()

        let emojiThemeItem = NSMenuItem(title: "Emoji", action: #selector(selectBadgeThemeClicked(_:)), keyEquivalent: "")
        emojiThemeItem.target = self
        emojiThemeItem.representedObject = BadgeThemeMode.funEmoji
        emojiThemeItem.state = currentTheme == .funEmoji ? .on : .off
        styleSubmenu.addItem(emojiThemeItem)

        let classicThemeItem = NSMenuItem(title: "Classic Traffic Light", action: #selector(selectBadgeThemeClicked(_:)), keyEquivalent: "")
        classicThemeItem.target = self
        classicThemeItem.representedObject = BadgeThemeMode.classic
        classicThemeItem.state = currentTheme == .classic ? .on : .off
        styleSubmenu.addItem(classicThemeItem)

        styleMenuItem.submenu = styleSubmenu
        appearanceSubmenu.addItem(styleMenuItem)

        // Customize Emoji Panel Action (Visible ONLY when Status Style is Emoji)
        if currentTheme == .funEmoji {
            appearanceSubmenu.addItem(NSMenuItem.separator())
            let customizeEmojiItem = NSMenuItem(title: "Customize Emoji…", action: #selector(openCustomizeStatusEmojiClicked), keyEquivalent: "")
            customizeEmojiItem.target = self
            appearanceSubmenu.addItem(customizeEmojiItem)
        }

        appearanceItem.submenu = appearanceSubmenu
        settingsSubmenu.addItem(appearanceItem)

        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)

        // 5. Quit Item
        let quitItem = NSMenuItem(title: "Quit AgentBridge", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleAgentMonitoredClicked(_ sender: NSMenuItem) {
        if let agent = sender.representedObject as? AgentID {
            let current = ConfigManager.shared.isAgentMonitored(agent)
            ConfigManager.shared.setAgentMonitored(agent, monitored: !current)
            print("👁️ Monitored state for \(agent.displayName) toggled to: \(!current)")
            updateTitleAndMenu()
        }
    }

    @objc private func selectOverworkThresholdClicked(_ sender: NSMenuItem) {
        if let mins = sender.representedObject as? Int {
            AgentStore.shared.overworkThresholdMinutes = mins
            var cfg = ConfigManager.shared.config
            cfg.overworkThresholdMinutes = mins
            ConfigManager.shared.saveConfig(cfg)
            print("⏱️ Overworking threshold set to: \(mins) min and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func selectBadgeThemeClicked(_ sender: NSMenuItem) {
        if let theme = sender.representedObject as? BadgeThemeMode {
            AgentStore.shared.currentTheme = theme
            var cfg = ConfigManager.shared.config
            cfg.badgeTheme = theme.rawValue
            ConfigManager.shared.saveConfig(cfg)
            print("🎨 Badge Theme set to: \(theme.displayName) and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func toggleBadgeThemeClicked() {
        if AgentStore.shared.currentTheme == .classic {
            AgentStore.shared.currentTheme = .funEmoji
        } else {
            AgentStore.shared.currentTheme = .classic
        }
        var cfg = ConfigManager.shared.config
        cfg.badgeTheme = AgentStore.shared.currentTheme.rawValue
        ConfigManager.shared.saveConfig(cfg)
        print("🎨 Badge Theme switched to: \(AgentStore.shared.currentTheme.displayName) and saved to config.json")
        updateTitleAndMenu()
    }

    @objc private func cycleOverworkThresholdClicked() {
        if AgentStore.shared.overworkThresholdMinutes == 5 {
            AgentStore.shared.overworkThresholdMinutes = 10
        } else if AgentStore.shared.overworkThresholdMinutes == 10 {
            AgentStore.shared.overworkThresholdMinutes = 15
        } else {
            AgentStore.shared.overworkThresholdMinutes = 5
        }
        var cfg = ConfigManager.shared.config
        cfg.overworkThresholdMinutes = AgentStore.shared.overworkThresholdMinutes
        ConfigManager.shared.saveConfig(cfg)
        print("⏱️ Overworking threshold updated to: \(AgentStore.shared.overworkThresholdMinutes) mins and saved to config.json")
        updateTitleAndMenu()
    }

    @objc private func selectAntiSleepModeClicked(_ sender: NSMenuItem) {
        if let modeOption = sender.representedObject as? AntiSleepMode {
            if modeOption == .timer1h {
                SleepManager.shared.setTimerMode(hours: 1)
            } else if modeOption == .timer3h {
                SleepManager.shared.setTimerMode(hours: 3)
            } else {
                SleepManager.shared.mode = modeOption
            }
            var cfg = ConfigManager.shared.config
            cfg.antiSleepMode = SleepManager.shared.mode.rawValue
            ConfigManager.shared.saveConfig(cfg)
            print("☕ Anti-Sleep Mode changed to: \(modeOption.displayName) and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func refreshUsageClicked() {
        print("🔄 Manual Usage Limits Refresh requested (stale-while-revalidate)...")
        isRefreshingUsage = true
        NSSound(named: "Pop")?.play()
        updateTitleAndMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            AutoMonitor.shared.refreshUsageNow()
            DispatchQueue.main.async {
                self?.isRefreshingUsage = false
                self?.lastUsageRefreshTime = Date()
                self?.updateTitleAndMenu()
            }
        }
    }

    @objc private func topActionClicked(_ sender: NSMenuItem) {
        if let agentInfo = sender.representedObject as? AgentInfo {
            perform1ClickSwitch(for: agentInfo.id, targetURL: agentInfo.webLink)
        }
    }

    @objc private func agentItemClicked(_ sender: NSMenuItem) {
        if let agent = sender.representedObject as? AgentID {
            let agentInfo = AgentStore.shared.getStatus(for: agent)
            perform1ClickSwitch(for: agent, targetURL: agentInfo.webLink)
        }
    }

    private func perform1ClickSwitch(for agent: AgentID, targetURL: String? = nil) {
        print("⚡ 1-Click Switch requested for \(agent.displayName)")

        if agent == .chatgpt {
            let info = AgentStore.shared.getStatus(for: .chatgpt)
            if let targetTabId = info.targetTabId {
                print("🎯 1-Click Switch using exact targetTabId=\(targetTabId)")
                HTTPServer.shared.requestTabFocus(tabId: targetTabId)
                WindowFocuser.focusAppOnly("com.google.Chrome")
            } else if let firstTabId = info.openTabs.first(where: { $0.tabId != nil })?.tabId {
                print("🎯 1-Click Switch using first open tabId=\(firstTabId)")
                HTTPServer.shared.requestTabFocus(tabId: firstTabId)
                WindowFocuser.focusAppOnly("com.google.Chrome")
            } else {
                print("⚠️ 1-Click Switch: No ChatGPT tabId available, using fallback")
                WindowFocuser.focusAgent(agent, targetURL: targetURL)
            }
        } else {
            WindowFocuser.focusAgent(agent, targetURL: targetURL)
        }

        AgentStore.shared.markChecked(for: agent)
        NotificationManager.shared.stopCurrentSound()
        updateTitleAndMenu()
    }

    @objc private func toggleOneShotSwitchClicked(_ sender: NSMenuItem) {
        if let dict = sender.representedObject as? [String: Any], let agent = dict["agent"] as? AgentID {
            let sessionId = dict["sessionId"] as? String
            let tabId = dict["tabId"] as? Int
            let url = dict["url"] as? String ?? dict["webLink"] as? String
            OneShotSwitchManager.shared.toggle(provider: agent, sessionId: sessionId, targetTabId: tabId, targetURL: url)
            updateTitleAndMenu()
        } else if let agent = sender.representedObject as? AgentID {
            let info = AgentStore.shared.getStatus(for: agent)
            let sessions = AgentStore.shared.getSessions(for: agent)
            let currentSessionId = sessions.first?.sessionId
            OneShotSwitchManager.shared.toggle(provider: agent, sessionId: currentSessionId, targetTabId: info.targetTabId, targetURL: info.webLink)
            updateTitleAndMenu()
        }
    }

    @objc private func sessionItemClicked(_ sender: NSMenuItem) {
        if let session = sender.representedObject as? AgentSessionInfo {
            print("⚡ Session item clicked for \(session.provider.displayName) (sessionId: \(session.sessionId))")
            AgentStore.shared.markSessionChecked(provider: session.provider, sessionId: session.sessionId, turnId: session.turnId)
            WindowFocuser.focusAgent(session.provider, targetURL: session.webLink)
            NotificationManager.shared.stopCurrentSound()
            updateTitleAndMenu()
        }
    }

    @objc private func openWebLinkClicked(_ sender: NSMenuItem) {
        if let dict = sender.representedObject as? [String: Any] {
            let urlStr = dict["url"] as? String ?? ""
            if let tabId = dict["tabId"] as? Int {
                print("🎯 Extension Tab Focus requested for tabId=\(tabId), url=\(urlStr)")
                AgentStore.shared.markSessionChecked(provider: .chatgpt, sessionId: "\(tabId)")
                HTTPServer.shared.requestTabFocus(tabId: tabId)
                WindowFocuser.focusAppOnly("com.google.Chrome")
            } else if !urlStr.isEmpty {
                WindowFocuser.focusURL(urlStr)
            }
        } else if let url = sender.representedObject as? URL {
            print("🌐 Opening URL in Browser: \(url.absoluteString)")
            WindowFocuser.focusURL(url.absoluteString)
        } else if let urlStr = sender.representedObject as? String {
            print("🌐 Opening URL in Browser: \(urlStr)")
            WindowFocuser.focusURL(urlStr)
        }
    }

    @objc public func openChromeExtensionsClicked(_ sender: Any?) {
        print("🧩 Opening Chrome Extensions page...")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? task.run()
    }

    @objc private func toggleNotificationsClicked() {
        var cfg = ConfigManager.shared.config
        let current = cfg.notificationsEnabled ?? true
        cfg.notificationsEnabled = !current
        ConfigManager.shared.saveConfig(cfg)
        print("🔔 macOS Banner Notifications toggled to: \(!current) and saved to config.json")
        updateTitleAndMenu()
    }

    @objc private func selectDoneSoundClicked(_ sender: NSMenuItem) {
        if let soundName = sender.representedObject as? String {
            var cfg = ConfigManager.shared.config
            cfg.doneSoundName = soundName
            ConfigManager.shared.saveConfig(cfg)
            NotificationManager.shared.playSound(named: soundName)
            print("🔊 Done Sound Effect updated to: \(soundName) and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func selectAttentionSoundClicked(_ sender: NSMenuItem) {
        if let soundName = sender.representedObject as? String {
            var cfg = ConfigManager.shared.config
            cfg.attentionSoundName = soundName
            ConfigManager.shared.saveConfig(cfg)
            NotificationManager.shared.playSound(named: soundName)
            print("🚨 Attention Sound Effect updated to: \(soundName) and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func stopSoundClicked() {
        NotificationManager.shared.stopCurrentSound()
        print("⏹️ Sound stopped")
    }

    @objc private func testNotificationClicked() {
        NotificationManager.shared.notify(
            agent: .chatgpt,
            oldStatus: .working,
            newStatus: .done,
            detail: "Test Notification Alert from AgentBridge!"
        )
    }

    @objc private func toggleOneShotTelegramNotifyClicked(_ sender: NSMenuItem) {
        if let dict = sender.representedObject as? [String: Any], let agent = dict["agent"] as? AgentID {
            let sessionId = dict["sessionId"] as? String
            let tabId = dict["tabId"] as? Int
            let url = dict["url"] as? String ?? dict["webLink"] as? String
            TelegramBridge.shared.toggleNotifyMeOverride(provider: agent, sessionId: sessionId ?? url, targetTabId: tabId)
            updateTitleAndMenu()
        } else if let agent = sender.representedObject as? AgentID {
            let info = AgentStore.shared.getStatus(for: agent)
            let sessions = AgentStore.shared.getSessions(for: agent)
            let currentSessionId = sessions.first?.sessionId
            TelegramBridge.shared.toggleNotifyMeOverride(provider: agent, sessionId: currentSessionId ?? info.webLink, targetTabId: info.targetTabId)
            updateTitleAndMenu()
        }
    }

    @objc private func selectTelegramDoneThresholdClicked(_ sender: NSMenuItem) {
        if let mins = sender.representedObject as? Int {
            ConfigManager.shared.setTelegramDoneThresholdMinutes(mins)
            print("⏱️ Telegram Done Threshold updated to \(mins == 0 ? "Off" : "\(mins) min") and saved to config.json")
            updateTitleAndMenu()
        }
    }

    @objc private func openCustomizeStatusEmojiClicked() {
        EmojiCustomizationController.shared.showWindow()
    }

    @objc private func resetStatusEmojiClicked() {
        ConfigManager.shared.resetStatusBadgesToDefaults()
        print("🎨 Status Badges reset to canonical defaults!")
        updateTitleAndMenu()
    }

    @objc private func toggleClosedLidModeClicked() {
        let current = SleepManager.shared.isClosedLidModeEnabled
        SleepManager.shared.isClosedLidModeEnabled = !current
        print("🛡️ Closed-Lid / Clamshell Mode toggled to: \(!current)")
        updateTitleAndMenu()
    }

    @objc private func toggleTelegramAlertsClicked() {
        let current = ConfigManager.shared.config.isTelegramEnabled ?? true
        ConfigManager.shared.setTelegramEnabled(!current)
        if !current {
            TelegramBridge.shared.startPollingIfEnabled()
        } else {
            TelegramBridge.shared.stopPolling()
        }
        print("📱 Telegram Alerts toggled to: \(!current)")
        updateTitleAndMenu()
    }

    @objc private func toggleTelegramQuotaAlertsClicked() {
        let current = ConfigManager.shared.config.isTelegramQuotaAlertsEnabled ?? true
        ConfigManager.shared.setTelegramQuotaAlertsEnabled(!current)
        print("📱 Telegram Quota Alerts toggled to: \(!current)")
        updateTitleAndMenu()
    }

    @objc private func sendTelegramTestNotificationClicked() {
        print("📱 Sending Telegram Test Notification...")
        NSSound(named: "Pop")?.play()
        Task {
            let res = await TelegramBridge.shared.sendTestNotification()
            if res.success {
                print("✅ Telegram Test Notification delivered successfully!")
            } else {
                print("❌ Telegram Test Notification delivery failed: \(res.description ?? "unknown")")
            }
            await MainActor.run {
                self.updateTitleAndMenu()
            }
        }
    }

    @objc private func setMenuBarModeCompactClicked() {
        var cfg = ConfigManager.shared.config
        cfg.menuBarDisplayMode = "compact"
        ConfigManager.shared.saveConfig(cfg)
        print("🖥️ Menu Bar View set to: compact")
        updateTitleAndMenu()
    }

    @objc private func setMenuBarModeDetailedClicked() {
        var cfg = ConfigManager.shared.config
        cfg.menuBarDisplayMode = "detailed"
        ConfigManager.shared.saveConfig(cfg)
        print("🖥️ Menu Bar View set to: detailed")
        updateTitleAndMenu()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
