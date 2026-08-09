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
                DispatchQueue.main.async {
                    self?.updateTitleAndMenu()
                }
            }

            AgentStore.shared.onStateChanged = { [weak self] agent, oldStatus, newStatus, detail in
                NotificationManager.shared.notify(agent: agent, oldStatus: oldStatus, newStatus: newStatus, detail: detail)
                DispatchQueue.main.async {
                    self?.updateTitleAndMenu()
                }
            }
        }
    }

    public func updateTitleAndMenu() {
        guard let item = statusItem, let button = item.button else { return }

        let summary = AgentStore.shared.overallSummary()
        button.title = "[\(summary)]"

        rebuildMenu()
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
            
            var durationTag = ""
            if info.status == .working, let start = info.thinkingStartTime {
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

            let sessionStr = info.activeSessionCount > 1 ? " (\(info.activeSessionCount) sessions)" : ""
            let nameTag = (info.sessionTitle?.isEmpty == false) ? " — \(info.sessionTitle!)" : ""

            let thinkingDur: TimeInterval? = info.thinkingStartTime != nil ? Date().timeIntervalSince(info.thinkingStartTime!) : nil
            let badge = info.status.badge(theme: currentTheme, thinkingDuration: thinkingDur, overworkThresholdMinutes: overworkMins)
            let statusLabel = info.status.statusTitle
            let title = "\(badge) \(agent.displayName)\(nameTag)\(sessionStr) [\(statusLabel)]\(durationTag)"

            let item = NSMenuItem(title: title, action: #selector(agentItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent

            // Submenu for Detailed Info & Open Tabs
            let submenu = NSMenu()

            if let sessionTitle = info.sessionTitle, !sessionTitle.isEmpty {
                let titleItem = NSMenuItem(title: "Active Session: \(sessionTitle)", action: nil, keyEquivalent: "")
                titleItem.isEnabled = false
                submenu.addItem(titleItem)
            }

            // List ALL Open ChatGPT Tabs in Submenu
            if agent == .chatgpt && !info.openTabs.isEmpty {
                let tabsHeader = NSMenuItem(title: "Open ChatGPT Tabs (\(info.openTabs.count)):", action: nil, keyEquivalent: "")
                tabsHeader.isEnabled = false
                submenu.addItem(tabsHeader)

                for (idx, tab) in info.openTabs.enumerated() {
                    let tabTitle = "   \(idx + 1). \(tab.title)"
                    let tabItem = NSMenuItem(title: tabTitle, action: #selector(openWebLinkClicked(_:)), keyEquivalent: "")
                    tabItem.target = self
                    if let url = URL(string: tab.url) {
                        tabItem.representedObject = url
                    }
                    submenu.addItem(tabItem)
                }
                submenu.addItem(NSMenuItem.separator())
            } else if let webLink = info.webLink, let url = URL(string: webLink), !webLink.isEmpty {
                let linkItem = NSMenuItem(title: "Open Web Link: \(webLink)", action: #selector(openWebLinkClicked(_:)), keyEquivalent: "")
                linkItem.target = self
                linkItem.representedObject = url
                submenu.addItem(linkItem)
            }

            let detailText = (info.detail?.isEmpty == false) ? info.detail! : "No recent activity"
            let detailItem = NSMenuItem(title: "Detail: \(detailText)", action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            submenu.addItem(detailItem)

            let sessionItem = NSMenuItem(title: "Active Sessions: \(info.activeSessionCount)", action: nil, keyEquivalent: "")
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

            let sPct = claudeUsage.sessionLimitPercent ?? 0.0
            let sBar = makeCompactBar(percent: sPct)
            let sReset = claudeUsage.sessionResetText ?? "resets in 4h 55m"
            let row1 = NSMenuItem(title: "     5-Hour:  \(sBar) \(Int(sPct))% used · \(sReset)", action: nil, keyEquivalent: "")
            row1.isEnabled = false
            menu.addItem(row1)

            let wPct = claudeUsage.weeklyLimitPercent ?? 45.0
            let wBar = makeCompactBar(percent: wPct)
            let wReset = claudeUsage.weeklyResetText ?? "resets Mon 11:00 PM"
            let row2 = NSMenuItem(title: "     Weekly:  \(wBar) \(Int(wPct))% used · \(wReset)", action: nil, keyEquivalent: "")
            row2.isEnabled = false
            menu.addItem(row2)
        }

        // 3B. Antigravity Usage Rows (Both Gemini Models & Claude/GPT Models)
        if let agyUsage = allUsage[.antigravity] {
            let hdr = NSMenuItem(title: "  Antigravity", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if let sPct = agyUsage.sessionLimitPercent {
                let bar = makeCompactBar(percent: sPct)
                let resetTag = agyUsage.sessionResetText ?? "resets in 23m"
                let row = NSMenuItem(title: "     Gemini 5-Hr:   \(bar) \(Int(sPct))% left · \(resetTag)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }

            if let wPct = agyUsage.weeklyLimitPercent {
                let bar = makeCompactBar(percent: wPct)
                let resetTag = agyUsage.weeklyResetText ?? "resets in 5d 9h"
                let row = NSMenuItem(title: "     Gemini Wkly:  \(bar) \(Int(wPct))% left · \(resetTag)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }

            let extraRow = NSMenuItem(title: "     Claude & GPT: 5-Hr 100% · Weekly 100% left", action: nil, keyEquivalent: "")
            extraRow.isEnabled = false
            menu.addItem(extraRow)
        }

        // 3C. Codex Desktop Usage Rows
        if let cdxUsage = allUsage[.codex] {
            let hdr = NSMenuItem(title: "  Codex Desktop", action: nil, keyEquivalent: "")
            hdr.isEnabled = false
            menu.addItem(hdr)

            if let wPct = cdxUsage.weeklyLimitPercent {
                let bar = makeCompactBar(percent: wPct)
                let resetTag = cdxUsage.weeklyResetText ?? "resets Aug 15"
                let row = NSMenuItem(title: "     Weekly:  \(bar) \(Int(wPct))% left · \(resetTag)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }

            let cardCount = cdxUsage.resetCardCount ?? 1
            let cardExpiry = cdxUsage.resetCardExpiryText ?? "Expires 8/12 7:51pm"
            let cardRow = NSMenuItem(title: "     \(cardCount) Reset Card (\(cardExpiry))", action: nil, keyEquivalent: "")
            cardRow.isEnabled = false
            menu.addItem(cardRow)
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

        settingsSubmenu.addItem(NSMenuItem.separator())

        // Mac Clamshell Anti-Sleep Controls
        let currentSleepMode = SleepManager.shared.mode
        let sleepMainItem = NSMenuItem(title: "Mac Anti-Sleep Mode (\(currentSleepMode.displayName))...", action: nil, keyEquivalent: "")
        let sleepSubmenu = NSMenu()
        for modeOption in AntiSleepMode.allCases {
            let item = NSMenuItem(title: modeOption.displayName, action: #selector(selectAntiSleepModeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = modeOption
            if modeOption == currentSleepMode {
                item.state = .on
            }
            sleepSubmenu.addItem(item)
        }
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
            print("☕ Anti-Sleep Mode changed to: \(modeOption.displayName)")
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
            perform1ClickSwitch(for: agentInfo.id)
        }
    }

    @objc private func agentItemClicked(_ sender: NSMenuItem) {
        if let agent = sender.representedObject as? AgentID {
            perform1ClickSwitch(for: agent)
        }
    }

    private func perform1ClickSwitch(for agent: AgentID) {
        print("⚡ 1-Click Switch requested for \(agent.displayName)")

        WindowFocuser.focusAgent(agent)
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
           let agent = dict["agent"] as? AgentID,
           let urlStr = dict["url"] as? String,
           let url = URL(string: urlStr) {
            print("🎯 Specific Tab Relay requested for \(agent.displayName) -> \(urlStr)")
            OutputRelayManager.shared.relayToChatGPT(from: agent)
            NSWorkspace.shared.open(url)
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

    @objc private func openWebLinkClicked(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            print("🌐 Opening URL in Browser: \(url)")
            NSWorkspace.shared.open(url)
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

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
