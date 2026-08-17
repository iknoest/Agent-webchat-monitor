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

    public func performUpdateTitleAndMenu() {
        lastRebuildTime = Date()
        renderExecutionCount += 1
        onPerformUpdateTitleAndMenu?()

        guard let item = statusItem, let button = item.button else { return }

        let displayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        if displayMode.lowercased() == "compact" {
            let compact = AgentStore.shared.compactSummary()
            button.title = "[\(compact)]"
        } else {
            let summary = AgentStore.shared.overallSummary()
            button.title = "[\(summary)]"
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
        let autoRelay = OutputRelayManager.shared.isAutoRelayEnabled
        let usageRefreshTs = lastUsageRefreshTime.timeIntervalSince1970

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



            stateDetails += "\(agent.rawValue):\(info.status.rawValue):\(info.availability.rawValue):\(info.detail ?? ""):\(info.activeSessionCount):\(info.sessionTitle ?? ""):\(info.webLink ?? ""):[\(openTabsStr)]:\(usage?.freshness ?? ""):\(usage?.sessionLimitPercent ?? 0):\(usage?.weeklyLimitPercent ?? 0):\(usage?.sessionResetText ?? ""):\(usage?.weeklyResetText ?? ""):\(usage?.isLiveSource ?? false):\(usage?.isQuotaExhausted ?? false);"
        }
        return "\(displayMode)|\(summary)|\(compact)|\(theme)|\(overwork)|\(notifyEnabled)|\(soundEnabled)|\(doneSound)|\(attentionSound)|\(sleepMode)|\(closedLid)|\(autoRelay)|\(usageRefreshTs)|\(sessionsStr)|\(stateDetails)"
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

    private func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()

        let currentTheme = AgentStore.shared.currentTheme
        let overworkMins = AgentStore.shared.overworkThresholdMinutes

        // 1. Header & Color Legend Submenu
        let headerItem = NSMenuItem(title: "Agent Signal Bar — 1-Click Priority Monitor", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Color Status Legend Submenu
        let legendItem = NSMenuItem(title: "  Status Color Guide...", action: nil, keyEquivalent: "")
        let legendSubmenu = NSMenu()

        if currentTheme == .classic {
            let l1 = NSMenuItem(title: "⚪ Idle / Ready", action: nil, keyEquivalent: "")
            l1.isEnabled = false
            legendSubmenu.addItem(l1)

            let l2 = NSMenuItem(title: "🟡 Working / Thinking / Generating", action: nil, keyEquivalent: "")
            l2.isEnabled = false
            legendSubmenu.addItem(l2)

            let l3 = NSMenuItem(title: "🟢 Output Ready! (Click to Jump / Focus)", action: nil, keyEquivalent: "")
            l3.isEnabled = false
            legendSubmenu.addItem(l3)

            let l4 = NSMenuItem(title: "🔴 Attention Required / Asking Permission Modal", action: nil, keyEquivalent: "")
            l4.isEnabled = false
            legendSubmenu.addItem(l4)

            let l5 = NSMenuItem(title: "⚫ App Process Closed / Out of Quota", action: nil, keyEquivalent: "")
            l5.isEnabled = false
            legendSubmenu.addItem(l5)
        } else {
            let l1 = NSMenuItem(title: "🫥 Idle / Ready", action: nil, keyEquivalent: "")
            l1.isEnabled = false
            legendSubmenu.addItem(l1)

            let l2 = NSMenuItem(title: "🤔 Working / Thinking (< \(overworkMins)m)", action: nil, keyEquivalent: "")
            l2.isEnabled = false
            legendSubmenu.addItem(l2)

            let l2b = NSMenuItem(title: "🥵 Overworking / Long Turn (> \(overworkMins)m)", action: nil, keyEquivalent: "")
            l2b.isEnabled = false
            legendSubmenu.addItem(l2b)

            let l3 = NSMenuItem(title: "🐶 Output Ready! (Click to Jump / Focus)", action: nil, keyEquivalent: "")
            l3.isEnabled = false
            legendSubmenu.addItem(l3)

            let l4 = NSMenuItem(title: "🥶 Attention Required / Asking Permission Modal", action: nil, keyEquivalent: "")
            l4.isEnabled = false
            legendSubmenu.addItem(l4)

            let l5 = NSMenuItem(title: "😴 App Process Closed / Offline", action: nil, keyEquivalent: "")
            l5.isEnabled = false
            legendSubmenu.addItem(l5)

            let l6 = NSMenuItem(title: "🤯 Out of Quota / Limit Exceeded", action: nil, keyEquivalent: "")
            l6.isEnabled = false
            legendSubmenu.addItem(l6)
        }

        legendItem.submenu = legendSubmenu
        menu.addItem(legendItem)

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

        // 2. Direct 1-Click Agent & Session Rows
        let allStates = AgentStore.shared.getAllStates()
        for agent in AgentID.allCases {
            let info = allStates[agent] ?? AgentInfo(id: agent)
            let providerSessions = AgentStore.shared.getSessions(for: agent)

            let isQuotaExhausted = (info.availability == .quotaExhausted) || (AgentUsageStore.shared.getUsage(for: agent)?.isQuotaExhausted == true)
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
                    let pct = Int(AgentUsageStore.shared.getUsage(for: .claude)?.sessionLimitPercent ?? 100.0)
                    durationTag = " [5-hour usage: \(pct)%]"
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
            let displayStatusLabel = (displayStatus == .quotaExhausted) ? "Quota Exhausted" : statusLabel
            let title = "\(badge) \(agent.displayName)\(nameTag)\(sessionStr) [\(displayStatusLabel)]\(durationTag)"

            let item = NSMenuItem(title: title, action: #selector(agentItemClicked(_:)), keyEquivalent: "")
            item.image = cachedDisplayDotImage(for: displayStatus)
            item.target = self
            item.representedObject = agent

            // Submenu for Detailed Info & Tracked Sessions
            let submenu = NSMenu()

            if isQuotaExhausted {
                let pct = Int(AgentUsageStore.shared.getUsage(for: agent)?.sessionLimitPercent ?? 100.0)
                let availItem = NSMenuItem(title: "Availability: Quota Exhausted (\(agent == .claude ? "5-hour usage: \(pct)%" : "100% used"))", action: nil, keyEquivalent: "")
                availItem.isEnabled = false
                submenu.addItem(availItem)
            }

            if let sessionTitle = info.sessionTitle, !sessionTitle.isEmpty {
                let compactTitle = sessionTitle.count > 45 ? String(sessionTitle.prefix(42)) + "..." : sessionTitle
                let titleItem = NSMenuItem(title: "Active Session: \(compactTitle)", action: nil, keyEquivalent: "")
                titleItem.isEnabled = false
                submenu.addItem(titleItem)
            }

            // List ALL Tracked Sessions in Submenu
            if agent == .chatgpt && !info.openTabs.isEmpty {
                let revTag = info.revision != nil ? " [rev: \(info.revision!)]" : ""
                let tabsHeader = NSMenuItem(title: "Open ChatGPT Tabs (\(info.openTabs.count))\(revTag):", action: nil, keyEquivalent: "")
                tabsHeader.isEnabled = false
                submenu.addItem(tabsHeader)

                for (idx, tab) in info.openTabs.enumerated() {
                    let tabStatus = AgentStatus(rawValue: tab.status) ?? .idle
                    let activeTag = (tab.active ?? false) ? " [Active Tab]" : ""
                    let rawTabTitle = tab.title
                    let compactTabTitle = rawTabTitle.count > 35 ? String(rawTabTitle.prefix(32)) + "..." : rawTabTitle
                    let tabTitle = " \(idx + 1). \(compactTabTitle)\(activeTag)"
                    let tabItem = NSMenuItem(title: tabTitle, action: #selector(openWebLinkClicked(_:)), keyEquivalent: "")
                    tabItem.image = cachedStatusDotImage(for: tabStatus)

                    tabItem.target = self
                    let repDict: [String: Any] = ["url": tab.url, "tabId": tab.tabId as Any]
                    tabItem.representedObject = repDict
                    submenu.addItem(tabItem)
                }
                submenu.addItem(NSMenuItem.separator())
            } else if !providerSessions.isEmpty {
                let sessHeader = NSMenuItem(title: "Tracked Sessions (\(providerSessions.count)):", action: nil, keyEquivalent: "")
                sessHeader.isEnabled = false
                submenu.addItem(sessHeader)

                for (idx, s) in providerSessions.enumerated() {
                    let compactTitle = s.title.count > 35 ? String(s.title.prefix(32)) + "..." : s.title
                    let ackTag = s.isAcknowledged ? " (Inspected)" : ""
                    let sTitle = " \(idx + 1). \(compactTitle) [\(s.status.statusTitle)\(ackTag)]"
                    let sItem = NSMenuItem(title: sTitle, action: #selector(sessionItemClicked(_:)), keyEquivalent: "")
                    sItem.image = cachedStatusDotImage(for: s.status)
                    sItem.target = self
                    sItem.representedObject = s
                    submenu.addItem(sItem)
                }
                submenu.addItem(NSMenuItem.separator())
            } else if let webLink = info.webLink, let url = URL(string: webLink), !webLink.isEmpty {
                let compactWebLink = webLink.count > 50 ? String(webLink.prefix(47)) + "..." : webLink
                let linkItem = NSMenuItem(title: "Open Web Link: \(compactWebLink)", action: #selector(openWebLinkClicked(_:)), keyEquivalent: "")
                linkItem.target = self
                linkItem.representedObject = url
                submenu.addItem(linkItem)
            }

            let detailText = (info.detail?.isEmpty == false) ? info.detail! : "No recent activity"
            let compactDetail = detailText.count > 45 ? String(detailText.prefix(42)) + "..." : detailText
            let detailItem = NSMenuItem(title: "Detail: \(compactDetail)", action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            submenu.addItem(detailItem)

            let sessionItem = NSMenuItem(title: "Tracked Sessions: \(providerSessions.count)", action: nil, keyEquivalent: "")
            sessionItem.isEnabled = false
            submenu.addItem(sessionItem)

            let directSwitchItem = NSMenuItem(title: "Focus / Switch Window Immediately", action: #selector(agentItemClicked(_:)), keyEquivalent: "")
            directSwitchItem.target = self
            directSwitchItem.representedObject = agent
            submenu.addItem(directSwitchItem)

            item.submenu = submenu
            menu.addItem(item)

            // FIRST-LEVEL DIRECT RELAY ACTIONS WITH MULTI-TAB TARGET SELECTOR
            if agent != .chatgpt {
                let gptInfo = allStates[.chatgpt]
                let tabs = gptInfo?.openTabs ?? []

                if tabs.count > 1 {
                    let relayMainItem = NSMenuItem(title: "    Relay Output -> ChatGPT Web (\(tabs.count) target tabs)", action: nil, keyEquivalent: "")
                    let relaySubmenu = NSMenu()

                    for (idx, tab) in tabs.enumerated() {
                        let tabItem = NSMenuItem(title: "Relay to Tab \(idx + 1): \(tab.title)", action: #selector(relayToSpecificTabClicked(_:)), keyEquivalent: "")
                        tabItem.target = self
                        tabItem.representedObject = ["agent": agent, "url": tab.url] as [String: Any]
                        relaySubmenu.addItem(tabItem)
                    }

                    relayMainItem.submenu = relaySubmenu
                    menu.addItem(relayMainItem)
                } else {
                    let gptTargetTag = (gptInfo?.sessionTitle?.isEmpty == false) ? " (\(gptInfo!.sessionTitle!))" : ""
                    let relayTitle = "    Relay Output -> ChatGPT Web\(gptTargetTag)"

                    let relayItem = NSMenuItem(title: relayTitle, action: #selector(relayOutputClicked(_:)), keyEquivalent: "")
                    relayItem.target = self
                    relayItem.representedObject = agent
                    menu.addItem(relayItem)
                }

                let copyItem = NSMenuItem(title: "    Copy Output -> Clipboard", action: #selector(copyOutputClicked(_:)), keyEquivalent: "")
                copyItem.target = self
                copyItem.representedObject = agent
                menu.addItem(copyItem)
            } else {
                // BI-DIRECTIONAL RELAY: ChatGPT Web -> Assigned Agents!
                let relayClaudeItem = NSMenuItem(title: "    Relay ChatGPT Output -> Claude Code", action: #selector(relayChatGPTToClaudeClicked), keyEquivalent: "")
                relayClaudeItem.target = self
                menu.addItem(relayClaudeItem)

                let relayAgyItem = NSMenuItem(title: "    Relay ChatGPT Output -> Antigravity", action: #selector(relayChatGPTToAgyClicked), keyEquivalent: "")
                relayAgyItem.target = self
                menu.addItem(relayAgyItem)

                let relayCdxItem = NSMenuItem(title: "    Relay ChatGPT Output -> Codex Desktop", action: #selector(relayChatGPTToCdxClicked), keyEquivalent: "")
                relayCdxItem.target = self
                menu.addItem(relayCdxItem)

                let copyGptItem = NSMenuItem(title: "    Copy ChatGPT Output -> Clipboard", action: #selector(copyOutputClicked(_:)), keyEquivalent: "")
                copyGptItem.target = self
                copyGptItem.representedObject = AgentID.chatgpt
                menu.addItem(copyGptItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // 3. SLEEK COMPACT AGENT USAGE & LIMITS DASHBOARD
        let usageHeaderItem = NSMenuItem(title: "AGENT USAGE & LIMITS DASHBOARD", action: nil, keyEquivalent: "")
        usageHeaderItem.isEnabled = false
        menu.addItem(usageHeaderItem)

        let allUsage = AgentUsageStore.shared.getAllUsage()

        // 3A. Claude Code Usage Rows
        if let claudeUsage = allUsage[.claude] {
            let hdr = NSMenuItem(title: "  Claude Code", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            let isStale = Date().timeIntervalSince(claudeUsage.lastUpdated) > 86400 || !claudeUsage.isLiveSource
            let freshnessTag = isStale ? " [Stale Data]" : ""

            if let sPct = claudeUsage.sessionLimitPercent {
                let sBar = makeCompactBar(percent: sPct)
                let sReset = claudeUsage.sessionResetText ?? ""
                let resetTag = sReset.isEmpty ? "" : " · \(sReset)"
                let row1 = NSMenuItem(title: "     5-Hour:  \(sBar) \(Int(sPct))% used\(resetTag)\(freshnessTag)", action: nil, keyEquivalent: "")
                row1.isEnabled = false
                menu.addItem(row1)
            } else {
                let unavail1 = NSMenuItem(title: "     5-Hour: [Unavailable]", action: nil, keyEquivalent: "")
                unavail1.isEnabled = false
                menu.addItem(unavail1)
            }

            if let wPct = claudeUsage.weeklyLimitPercent {
                let wBar = makeCompactBar(percent: wPct)
                let wReset = claudeUsage.weeklyResetText ?? ""
                let resetTag = wReset.isEmpty ? "" : " · \(wReset)"
                let row2 = NSMenuItem(title: "     Weekly:  \(wBar) \(Int(wPct))% used\(resetTag)\(freshnessTag)", action: nil, keyEquivalent: "")
                row2.isEnabled = false
                menu.addItem(row2)
            } else {
                let unavail2 = NSMenuItem(title: "     Weekly: [Unavailable]", action: nil, keyEquivalent: "")
                unavail2.isEnabled = false
                menu.addItem(unavail2)
            }
        }

        // 3B. Antigravity Usage Rows
        if let agyUsage = allUsage[.antigravity] {
            let hdr = NSMenuItem(title: "  Antigravity", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if agyUsage.isLiveSource, let sPct = agyUsage.sessionLimitPercent {
                let bar = makeCompactBar(percent: sPct)
                let resetTag = agyUsage.sessionResetText ?? ""
                let row = NSMenuItem(title: "     Gemini 5-Hr:   \(bar) \(Int(sPct))% left · \(resetTag)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            } else {
                let unavailRow = NSMenuItem(title: "     Quota: [Live disk quota unavailable]", action: nil, keyEquivalent: "")
                unavailRow.isEnabled = false
                menu.addItem(unavailRow)
            }
        }

        // 3C. Codex Desktop Usage Rows
        if let cdxUsage = allUsage[.codex] {
            let hdr = NSMenuItem(title: "  Codex Desktop", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if cdxUsage.isLiveSource, let wPct = cdxUsage.weeklyLimitPercent {
                let bar = makeCompactBar(percent: wPct)
                let resetTag = cdxUsage.weeklyResetText ?? ""
                let row = NSMenuItem(title: "     Weekly:  \(bar) \(Int(wPct))% left · \(resetTag)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            } else {
                let unavailRow = NSMenuItem(title: "     Quota: [Live disk quota unavailable]", action: nil, keyEquivalent: "")
                unavailRow.isEnabled = false
                menu.addItem(unavailRow)
            }
        }

        // 3D. Interactive Refresh Button (Updated Xm ago)
        let refreshUsageTitle = "  Refresh Usage Limits (Updated \(lastUsageRefreshTime.relativeString()))"
        let refreshUsageItem = NSMenuItem(title: refreshUsageTitle, action: #selector(refreshUsageClicked), keyEquivalent: "r")
        refreshUsageItem.target = self
        menu.addItem(refreshUsageItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Clean Settings & Preferences Submenu
        let settingsItem = NSMenuItem(title: "Settings & Audio Preferences...", action: nil, keyEquivalent: ",")
        let settingsSubmenu = NSMenu()

        // Theme Switcher Item (Shows the ACTION option to switch TO)
        let themeActionTitle: String
        if currentTheme == .classic {
            themeActionTitle = "Switch Badge Theme to: Fun Emojis (🫥🤔🥵🐶🥶😴🤯)"
        } else {
            themeActionTitle = "Switch Badge Theme to: Classic Colored Balls (⚪🟡🟢🔴⚫)"
        }
        let themeToggleItem = NSMenuItem(title: themeActionTitle, action: #selector(toggleBadgeThemeClicked), keyEquivalent: "")
        themeToggleItem.target = self
        settingsSubmenu.addItem(themeToggleItem)

        let overworkTitle = "Overworking Threshold: \(overworkMins) mins (Click to Cycle 5m/10m/15m)"
        let overworkToggleItem = NSMenuItem(title: overworkTitle, action: #selector(cycleOverworkThresholdClicked), keyEquivalent: "")
        overworkToggleItem.target = self
        settingsSubmenu.addItem(overworkToggleItem)

        // Menu Bar View (Detailed vs Compact)
        let currentDisplayMode = ConfigManager.shared.config.menuBarDisplayMode ?? "detailed"
        let isDetailedView = currentDisplayMode.lowercased() != "compact"
        let viewMenuItem = NSMenuItem(title: "Menu Bar View", action: nil, keyEquivalent: "")
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
        settingsSubmenu.addItem(viewMenuItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // Mac Clamshell Anti-Sleep Controls
        let currentSleepMode = SleepManager.shared.mode
        let sleepStateTag = SleepManager.shared.isAssertionActive ? " [☕ ACTIVE]" : " [💤 IDLE]"
        let sleepMainItem = NSMenuItem(title: "Mac Anti-Sleep Mode (\(currentSleepMode.displayName))\(sleepStateTag)...", action: nil, keyEquivalent: "")
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
        let closedLidTitle = isClosedLid ? "Closed-Lid / Clamshell Mode (pmset): ON (Click to Disable)\(privTag)" : "Closed-Lid / Clamshell Mode (pmset): OFF (Click to Enable)\(privTag)"
        let closedLidItem = NSMenuItem(title: closedLidTitle, action: #selector(toggleClosedLidModeClicked), keyEquivalent: "")
        closedLidItem.target = self
        if isClosedLid {
            closedLidItem.state = .on
        }
        sleepSubmenu.addItem(closedLidItem)

        sleepMainItem.submenu = sleepSubmenu
        settingsSubmenu.addItem(sleepMainItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // macOS Banner Notifications Toggle Item
        let isNotifyEnabled = ConfigManager.shared.config.notificationsEnabled ?? true
        let notifyTitle = isNotifyEnabled ? "macOS Pop-up Banners: ON (Click to Disable)" : "macOS Pop-up Banners: OFF (Click to Enable)"
        let notifyToggleItem = NSMenuItem(title: notifyTitle, action: #selector(toggleNotificationsClicked), keyEquivalent: "")
        notifyToggleItem.target = self
        settingsSubmenu.addItem(notifyToggleItem)

        let soundEnabled = NotificationManager.shared.soundEnabled
        let soundTitle = soundEnabled ? "Sound Alerts: ON (Click to Mute)" : "Sound Alerts: OFF (Click to Unmute)"
        let soundToggleItem = NSMenuItem(title: soundTitle, action: #selector(toggleSoundClicked), keyEquivalent: "")
        soundToggleItem.target = self
        settingsSubmenu.addItem(soundToggleItem)

        // Completion Sound Selector Submenu (Directly under Settings)
        let currentDoneSound = ConfigManager.shared.config.doneSoundName ?? "Glass"
        let doneSoundItem = NSMenuItem(title: "Completion Sound (\(currentDoneSound))...", action: nil, keyEquivalent: "")
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
        settingsSubmenu.addItem(doneSoundItem)

        // Attention Required Sound Selector Submenu (Directly under Settings)
        let currentAttentionSound = ConfigManager.shared.config.attentionSoundName ?? "Basso"
        let attentionSoundItem = NSMenuItem(title: "Attention Required Sound (\(currentAttentionSound))...", action: nil, keyEquivalent: "")
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
        settingsSubmenu.addItem(attentionSoundItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        let isAutoRelay = OutputRelayManager.shared.isAutoRelayEnabled
        let autoRelayTitle = isAutoRelay ? "Auto-Relay Output to ChatGPT: ON (Click to Disable)" : "Auto-Relay Output to ChatGPT: OFF (Click to Enable)"
        let autoRelayItem = NSMenuItem(title: autoRelayTitle, action: #selector(toggleAutoRelayClicked), keyEquivalent: "")
        autoRelayItem.target = self
        settingsSubmenu.addItem(autoRelayItem)

        let openConfigItem = NSMenuItem(title: "Edit Custom Logos & Badges (config.json)...", action: #selector(openConfigClicked), keyEquivalent: "")
        openConfigItem.target = self
        settingsSubmenu.addItem(openConfigItem)

        let openIconsFolderItem = NSMenuItem(title: "Open Icons Folder (~/.config/AgentSignalBar/icons)", action: #selector(openIconsFolderClicked), keyEquivalent: "")
        openIconsFolderItem.target = self
        settingsSubmenu.addItem(openIconsFolderItem)

        let reloadConfigItem = NSMenuItem(title: "Reload Custom Config & Icons", action: #selector(reloadConfigClicked), keyEquivalent: "")
        reloadConfigItem.target = self
        settingsSubmenu.addItem(reloadConfigItem)

        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)

        // 5. Quit Item
        let quitItem = NSMenuItem(title: "Quit AgentSignalBar", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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

    @objc private func relayChatGPTToClaudeClicked() {
        OutputRelayManager.shared.relayChatGPTToAgent(targetAgent: .claude)
    }

    @objc private func relayChatGPTToAgyClicked() {
        OutputRelayManager.shared.relayChatGPTToAgent(targetAgent: .antigravity)
    }

    @objc private func relayChatGPTToCdxClicked() {
        OutputRelayManager.shared.relayChatGPTToAgent(targetAgent: .codex)
    }

    @objc private func refreshUsageClicked() {
        print("🔄 Manual Usage Limits Refresh requested...")
        ConfigManager.shared.loadConfig()
        AgentUsageStore.shared.reloadFromConfig()
        lastUsageRefreshTime = Date()
        NSSound(named: "Pop")?.play()
        updateTitleAndMenu()
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

    @objc private func relayOutputClicked(_ sender: NSMenuItem) {
        if let agent = sender.representedObject as? AgentID {
            print("📲 Manual relay requested for \(agent.displayName)")
            OutputRelayManager.shared.relayToChatGPT(from: agent)
        }
    }

    @objc private func relayToSpecificTabClicked(_ sender: NSMenuItem) {
        if let dict = sender.representedObject as? [String: Any],
           let agent = dict["agent"] as? AgentID {
            let urlStr = dict["url"] as? String ?? ""
            print("🎯 Specific Tab Relay requested for \(agent.displayName) -> \(urlStr)")
            OutputRelayManager.shared.relayToChatGPT(from: agent)
            if let tabId = dict["tabId"] as? Int {
                HTTPServer.shared.requestTabFocus(tabId: tabId)
                WindowFocuser.focusAppOnly("com.google.Chrome")
            } else if !urlStr.isEmpty {
                WindowFocuser.focusURL(urlStr)
            }
        }
    }

    @objc private func copyOutputClicked(_ sender: NSMenuItem) {
        if let agent = sender.representedObject as? AgentID {
            let success = OutputRelayManager.shared.copyToClipboard(from: agent)
            print("📋 Copy to clipboard requested for \(agent.displayName) -> \(success)")
        }
    }

    @objc private func toggleAutoRelayClicked() {
        OutputRelayManager.shared.isAutoRelayEnabled.toggle()
        print("⚡ Auto-Relay toggled: \(OutputRelayManager.shared.isAutoRelayEnabled)")
        updateTitleAndMenu()
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

    @objc private func toggleSoundClicked() {
        let newState = NotificationManager.shared.toggleSound()
        print("🔊 Sound toggled: \(newState)")
        updateTitleAndMenu()
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
