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
                button.title = "AgentSignalBar"
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
        let quotaExhaustedLabel = (theme == .funEmoji) ? "\(quotaExhaustedBadge) [⦸] Quota Exhausted / Rate Limited" : "⦸ Quota Exhausted / Rate Limited"
        items.append((.quotaExhausted, quotaExhaustedBadge, quotaExhaustedLabel, "Provider usage limit reached; turn halted"))

        let quotaRestoredBadge = EffectiveDisplayStatus.quotaRestored.badge(theme: theme)
        let quotaRestoredLabel = (theme == .funEmoji) ? "\(quotaRestoredBadge) Quota Restored / Ready Again" : "\(quotaRestoredBadge) [Quota Restored] Quota Recovered / Ready Again"
        items.append((.quotaRestored, quotaRestoredBadge, quotaRestoredLabel, "Provider recovered quota (>0% remaining after exhaustion); standby for prompt"))

        let idleBadge = EffectiveDisplayStatus.idle.badge(theme: theme)
        items.append((.idle, idleBadge, "\(idleBadge) Idle / Standby", "Agent process is running and standby for input"))

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
            if monitored.isEmpty {
                result.append(NSAttributedString(string: "-"))
            } else {
                for (idx, agent) in monitored.enumerated() {
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

        return "\(displayMode)|\(summary)|\(compact)|\(theme)|\(overwork)|\(notifyEnabled)|\(soundEnabled)|\(doneSound)|\(attentionSound)|\(sleepMode)|\(closedLid)|\(refreshingTag)|\(axTrusted)|\(disabledAgents)|\(armedWatchTag)|\(tgEnabled):\(tgConfigured):\(tgLastTest)|\(sessionsStr)|\(stateDetails)"
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

    private func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()

        let currentTheme = AgentStore.shared.currentTheme
        let overworkMins = AgentStore.shared.overworkThresholdMinutes

        // 1. Header & Color Legend Submenu
        let headerItem = NSMenuItem(title: "Agent Signal Bar — 1-Click Priority Monitor", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

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

        let themeHeading = NSMenuItem(title: "Current Theme: \(currentTheme == .funEmoji ? "Fun Emojis (🫥🤔🥵🐶🥶😴🤯)" : "Classic Colored Balls (⚪🟡🟢🔴⚫)")", action: nil, keyEquivalent: "")
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
            if displayStatus == .quotaRestored {
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

            if agent == .chatgpt && !info.openTabs.isEmpty {
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
            }

            let detailItem = NSMenuItem(title: "Detail: \(info.detail ?? "No active task")", action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            submenu.addItem(detailItem)

            let timeItem = NSMenuItem(title: "Last Update: \(info.lastUpdated.relativeString())", action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            submenu.addItem(timeItem)

            if info.status != .off {
                submenu.addItem(NSMenuItem.separator())
                let isArmed = OneShotSwitchManager.shared.isArmed(provider: agent, sessionId: info.sessionTitle, targetTabId: info.targetTabId)
                let switchItem = NSMenuItem(title: "Auto-Switch When Ready", action: #selector(toggleOneShotSwitchClicked(_:)), keyEquivalent: "")
                switchItem.target = self
                switchItem.state = isArmed ? .on : .off
                switchItem.representedObject = ["agent": agent, "sessionTitle": info.sessionTitle as Any, "tabId": info.targetTabId as Any, "webLink": info.webLink as Any]
                submenu.addItem(switchItem)
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

            if let sRemaining = claudeUsage.sessionRemainingPercent {
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

                    if let sRemaining = family.sessionRemainingPercent {
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

        // 4D. Telegram Alerts Submenu
        let telegramItem = NSMenuItem(title: "Telegram Alerts", action: nil, keyEquivalent: "")
        let telegramSubmenu = NSMenu()

        let tgConfig = EnvConfigLoader.shared.getTelegramConfig()
        let isTelegramEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true

        let tgToggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleTelegramAlertsClicked), keyEquivalent: "")
        tgToggleItem.target = self
        tgToggleItem.state = (isTelegramEnabled && tgConfig.isConfigured) ? .on : .off
        if !tgConfig.isConfigured {
            tgToggleItem.isEnabled = false
        }
        telegramSubmenu.addItem(tgToggleItem)

        let sendTestItem = NSMenuItem(title: "Send Test Notification", action: #selector(sendTelegramTestNotificationClicked), keyEquivalent: "")
        sendTestItem.target = self
        if !tgConfig.isConfigured {
            sendTestItem.isEnabled = false
        }
        telegramSubmenu.addItem(sendTestItem)

        telegramSubmenu.addItem(NSMenuItem.separator())
        let statusText = tgConfig.isConfigured ? "Status: Configured (.env)" : "Status: Not Configured (.env missing)"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        telegramSubmenu.addItem(statusItem)

        if let last = TelegramBridge.shared.lastDeliveryResult {
            let lastItem = NSMenuItem(title: "Last Test: \(last.safeSummary)", action: nil, keyEquivalent: "")
            lastItem.isEnabled = false
            telegramSubmenu.addItem(lastItem)
        }

        telegramItem.submenu = telegramSubmenu
        settingsSubmenu.addItem(telegramItem)

        // 4E. Appearance Submenu
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceSubmenu = NSMenu()

        // Menu Bar View (Detailed vs Compact)
        let currentDisplayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        let isDetailedView = currentDisplayMode.lowercased() != "compact"
        let viewMenuItem = NSMenuItem(title: "Menu Bar View: \(isDetailedView ? "Detailed" : "Compact")", action: nil, keyEquivalent: "")
        let viewSubmenu = NSMenu()

        let detailedItem = NSMenuItem(title: "Detailed (All Providers)", action: #selector(setMenuBarModeDetailedClicked), keyEquivalent: "")
        detailedItem.target = self
        detailedItem.state = isDetailedView ? .on : .off
        viewSubmenu.addItem(detailedItem)

        let compactItem = NSMenuItem(title: "Compact (Single Indicator)", action: #selector(setMenuBarModeCompactClicked), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = !isDetailedView ? .on : .off
        viewSubmenu.addItem(compactItem)

        viewMenuItem.submenu = viewSubmenu
        appearanceSubmenu.addItem(viewMenuItem)

        // Badge Theme Submenu
        let themeTitle = currentTheme == .funEmoji ? "Badge Theme: Fun" : "Badge Theme: Classic"
        let themeMenuItem = NSMenuItem(title: themeTitle, action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu()

        let funThemeItem = NSMenuItem(title: "Fun Emojis (🫥🤔🥵🐶🥶😴🤯)", action: #selector(selectBadgeThemeClicked(_:)), keyEquivalent: "")
        funThemeItem.target = self
        funThemeItem.representedObject = BadgeThemeMode.funEmoji
        funThemeItem.state = currentTheme == .funEmoji ? .on : .off
        themeSubmenu.addItem(funThemeItem)

        let classicThemeItem = NSMenuItem(title: "Classic Colored Balls (⚪🟡🟢🔴⚫)", action: #selector(selectBadgeThemeClicked(_:)), keyEquivalent: "")
        classicThemeItem.target = self
        classicThemeItem.representedObject = BadgeThemeMode.classic
        classicThemeItem.state = currentTheme == .classic ? .on : .off
        themeSubmenu.addItem(classicThemeItem)

        themeMenuItem.submenu = themeSubmenu
        appearanceSubmenu.addItem(themeMenuItem)

        // Custom Icons Submenu
        let customIconsItem = NSMenuItem(title: "Custom Icons", action: nil, keyEquivalent: "")
        let customIconsSubmenu = NSMenu()

        let openConfigItem = NSMenuItem(title: "Edit Config… (config.json)", action: #selector(openConfigClicked), keyEquivalent: "")
        openConfigItem.target = self
        customIconsSubmenu.addItem(openConfigItem)

        let openIconsFolderItem = NSMenuItem(title: "Open Icons Folder (~/.config/AgentSignalBar/icons)", action: #selector(openIconsFolderClicked), keyEquivalent: "")
        openIconsFolderItem.target = self
        customIconsSubmenu.addItem(openIconsFolderItem)

        let reloadConfigItem = NSMenuItem(title: "Reload Icons", action: #selector(reloadConfigClicked), keyEquivalent: "")
        reloadConfigItem.target = self
        customIconsSubmenu.addItem(reloadConfigItem)

        customIconsItem.submenu = customIconsSubmenu
        appearanceSubmenu.addItem(customIconsItem)

        appearanceItem.submenu = appearanceSubmenu
        settingsSubmenu.addItem(appearanceItem)

        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)

        // 5. Quit Item
        let quitItem = NSMenuItem(title: "Quit AgentSignalBar", action: #selector(quitClicked), keyEquivalent: "q")
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
            let sessionTitle = dict["sessionTitle"] as? String
            let tabId = dict["tabId"] as? Int
            let url = dict["url"] as? String ?? dict["webLink"] as? String
            OneShotSwitchManager.shared.toggle(provider: agent, sessionId: sessionTitle, targetTabId: tabId, targetURL: url)
            updateTitleAndMenu()
        } else if let agent = sender.representedObject as? AgentID {
            let info = AgentStore.shared.getStatus(for: agent)
            OneShotSwitchManager.shared.toggle(provider: agent, sessionId: info.sessionTitle, targetTabId: info.targetTabId, targetURL: info.webLink)
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

    @objc private func openConfigClicked() {
        print("🎨 Opening config.json in TextEdit...")
        ConfigManager.shared.openConfigFileInEditor()
    }

    @objc private func openIconsFolderClicked() {
        print("📁 Opening icons directory in Finder...")
        ConfigManager.shared.openIconsFolder()
    }

    @objc private func reloadConfigClicked() {
        print("🔄 Reloading config.json...")
        ConfigManager.shared.loadConfig()
        updateTitleAndMenu()
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
            detail: "Test Notification Alert from AgentSignalBar!"
        )
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
