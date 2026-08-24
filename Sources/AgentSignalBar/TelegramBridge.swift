import Foundation

public final class TelegramBridge: @unchecked Sendable {
    public static let shared = TelegramBridge()

    private let lock = NSLock()
    public var transport: TelegramTransportProtocol
    private var pollingTask: Task<Void, Never>?
    public private(set) var isPollingActive: Bool = false
    public private(set) var lastDeliveryResult: TelegramDeliveryResult?
    private var lastUpdateId: Int64 = 0
    private var lastSentNotificationKeys: [String: Date] = [:]
    private var activeOverrides: [String: TelegramNotifyOverride] = [:]

    public struct TelegramNotifyOverride: Equatable, Sendable {
        public let provider: AgentID
        public let sessionId: String?
        public let targetTabId: Int?
        public let turnId: String?
        public let armedAt: Date

        public init(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, turnId: String? = nil, armedAt: Date = Date()) {
            self.provider = provider
            self.sessionId = sessionId
            self.targetTabId = targetTabId
            self.turnId = turnId
            self.armedAt = armedAt
        }
    }

    public init(transport: TelegramTransportProtocol = URLSessionTelegramTransport()) {
        self.transport = transport
    }

    public func makeSessionKey(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, webLink: String? = nil) -> String {
        if let tabId = targetTabId {
            return "\(provider.rawValue)_tab_\(tabId)"
        }
        if let sId = sessionId, !sId.isEmpty {
            return "\(provider.rawValue)_sess_\(sId)"
        }
        if let link = webLink, !link.isEmpty {
            return "\(provider.rawValue)_sess_\(link)"
        }
        return "\(provider.rawValue)_sess_root"
    }

    /// Persistent opt-out model: all top-level user sessions default to completion notifications enabled (true)
    public func isSessionCompletionEnabled(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, webLink: String? = nil) -> Bool {
        let key = makeSessionKey(provider: provider, sessionId: sessionId, targetTabId: targetTabId, webLink: webLink)
        return !ConfigManager.shared.isSessionCompletionMuted(key: key)
    }

    public func setSessionCompletionEnabled(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, webLink: String? = nil, enabled: Bool) {
        let key = makeSessionKey(provider: provider, sessionId: sessionId, targetTabId: targetTabId, webLink: webLink)
        ConfigManager.shared.setSessionCompletionMuted(key: key, muted: !enabled)
        print("🔔 Telegram completion alert \(enabled ? "enabled" : "muted") for \(provider.displayName) [\(key)]")
    }

    public func toggleSessionCompletionEnabled(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, webLink: String? = nil) {
        let current = isSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId, webLink: webLink)
        setSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId, webLink: webLink, enabled: !current)
    }

    // Compatibility methods
    public func isNotifyMeOverrideActive(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil) -> Bool {
        return isSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId)
    }

    public func setNotifyMeOverride(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, turnId: String? = nil) {
        setSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId, enabled: true)
    }

    public func clearNotifyMeOverride(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil) {
        setSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId, enabled: false)
    }

    public func toggleNotifyMeOverride(provider: AgentID, sessionId: String? = nil, targetTabId: Int? = nil, turnId: String? = nil) {
        toggleSessionCompletionEnabled(provider: provider, sessionId: sessionId, targetTabId: targetTabId)
    }

    public func setup() {
        // Register observer on AgentStore for outbound lifecycle alerts
        AgentStore.shared.addObserver(id: "TelegramBridge") { [weak self] agent, oldStatus, newStatus, detail in
            self?.handleAgentStatusChange(agent: agent, oldStatus: oldStatus, newStatus: newStatus, detail: detail)
        }

        // Register observer on NetworkHealthMonitor for global connectivity alerts
        NetworkHealthMonitor.shared.onConnectivityChange = { [weak self] connected in
            self?.handleNetworkHealthChange(isConnected: connected)
        }

        // Start polling if enabled and configured
        startPollingIfEnabled()
    }

    public func startPollingIfEnabled() {
        lock.lock()
        let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        let config = EnvConfigLoader.shared.getTelegramConfig()
        let alreadyActive = isPollingActive
        lock.unlock()

        if isEnabled && config.isConfigured && !alreadyActive {
            startPolling()
        }
    }

    public func startPolling() {
        lock.lock()
        if isPollingActive {
            lock.unlock()
            return
        }
        isPollingActive = true
        lock.unlock()

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            var failureBackoffSeconds: UInt64 = 2

            while !Task.isCancelled {
                guard let self = self else { break }

                let config = EnvConfigLoader.shared.getTelegramConfig()
                guard config.isConfigured else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }

                let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
                guard isEnabled else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }

                do {
                    let offset: Int? = self.lastUpdateId > 0 ? Int(self.lastUpdateId + 1) : nil
                    let updates = try await self.transport.getUpdates(
                        botToken: config.botToken,
                        offset: offset,
                        timeout: 20
                    )

                    failureBackoffSeconds = 2 // Reset backoff on success

                    for update in updates {
                        if update.update_id > self.lastUpdateId {
                            self.lastUpdateId = update.update_id
                        }

                        if let msg = update.message {
                            if let reply = await TelegramCommandRouter.shared.handleIncomingMessage(msg, configuredChatId: config.chatId) {
                                let res = try? await self.transport.sendMessage(
                                    botToken: config.botToken,
                                    chatId: config.chatId,
                                    text: reply.text,
                                    parseMode: reply.parseMode
                                )
                                if let res = res {
                                    self.lastDeliveryResult = res
                                }
                            }
                        }
                    }
                } catch {
                    // Backoff on network failure without blocking main thread or crashing
                    try? await Task.sleep(nanoseconds: failureBackoffSeconds * 1_000_000_000)
                    failureBackoffSeconds = min(failureBackoffSeconds * 2, 15)
                }
            }
        }
    }

    public func stopPolling() {
        lock.lock()
        isPollingActive = false
        pollingTask?.cancel()
        pollingTask = nil
        lock.unlock()
    }

    public func sendTestNotification() async -> TelegramDeliveryResult {
        let config = EnvConfigLoader.shared.getTelegramConfig()
        guard config.isConfigured else {
            let res = TelegramDeliveryResult(success: false, httpStatus: 0, errorCode: nil, description: "Telegram credentials not configured in .env")
            self.lastDeliveryResult = res
            return res
        }

        let testMessage = "✅ AgentBridge Telegram alerts connected"
        do {
            let res = try await transport.sendMessage(
                botToken: config.botToken,
                chatId: config.chatId,
                text: testMessage,
                parseMode: nil
            )
            self.lastDeliveryResult = res
            return res
        } catch {
            let res = TelegramDeliveryResult(success: false, httpStatus: 0, errorCode: nil, description: error.localizedDescription)
            self.lastDeliveryResult = res
            return res
        }
    }

    public func handleAgentStatusChange(agent: AgentID, oldStatus: AgentStatus, newStatus: AgentStatus, detail: String?) {
        // 1. Monitored Agents Gate: disabled providers must never trigger alerts
        guard ConfigManager.shared.isAgentMonitored(agent) else { return }

        // 2. Telegram Enabled Gate
        let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        guard isEnabled else { return }

        // 3. Configuration Gate
        let config = EnvConfigLoader.shared.getTelegramConfig()
        guard config.isConfigured else { return }

        // 4. Outbound Lifecycle Event Filtering: ONLY Needs You (blocked) and Done (done)
        guard newStatus == .blocked || newStatus == .done else { return }

        let info = AgentStore.shared.getStatus(for: agent)
        let relevantSession = AgentStore.shared.getSessions(for: agent).first(where: { $0.status == newStatus })
        let sessionId = relevantSession?.sessionId ?? "parent"
        let turnId = relevantSession?.turnId ?? info.turnId ?? "turn"

        // 5. Completion Alerts Policy: Persistent Opt-Out and Optional Minimum Runtime
        if newStatus == .done {
            let isEnabledForSession = isSessionCompletionEnabled(
                provider: agent,
                sessionId: relevantSession?.sessionId,
                targetTabId: relevantSession?.targetTabId ?? info.targetTabId,
                webLink: relevantSession?.webLink ?? info.webLink
            )

            guard isEnabledForSession else {
                print("🔕 Suppressed Telegram Completion alert for \(agent.displayName): session completion alert is muted")
                return
            }

            let thresholdMinutes = ConfigManager.shared.config.telegramDoneThresholdMinutes ?? 0
            if thresholdMinutes > 0 {
                // Minimum runtime noise filter configured (e.g. 1m, 3m, 5m, 10m, 15m)
                guard let dur = relevantSession?.lastDurationSeconds ?? info.lastDurationSeconds, dur > 0 else {
                    print("🔕 Suppressed Telegram Completion alert for \(agent.displayName): duration is unknown with minimum runtime \(thresholdMinutes)m")
                    return
                }

                let thresholdSeconds = Double(thresholdMinutes * 60)
                guard dur >= thresholdSeconds else {
                    print("🔕 Suppressed Telegram Completion alert for \(agent.displayName): runtime (\(Int(dur))s) < threshold (\(Int(thresholdSeconds))s)")
                    return
                }
            }
            // If thresholdMinutes == 0 (Off), no duration filter is applied; all unmuted sessions notify immediately!
        }

        // 6. Deduplication Gate
        let dedupeKey = "\(agent.rawValue)_\(sessionId)_\(turnId)_\(newStatus.rawValue)"

        lock.lock()
        if lastSentNotificationKeys[dedupeKey] != nil {
            lock.unlock()
            return // Suppress duplicate notification for identical turn/state
        }
        lastSentNotificationKeys[dedupeKey] = Date()
        lock.unlock()

        // 7. Format Privacy-Safe Outbound Notification
        let safeProject = TelegramPrivacySafeContext.resolveSafeProjectContext(agent: agent, session: relevantSession)
        let text: String

        if newStatus == .blocked {
            let rawReason = relevantSession?.attentionReason ?? detail ?? "User input or permission required"
            let safeReason = TelegramPrivacySafeContext.sanitizeAttentionReason(rawReason)
            text = """
            🔴 \(agent.displayName) needs you
            Project: \(safeProject)
            \(safeReason)
            """
        } else {
            var durText = ""
            if let dur = relevantSession?.lastDurationSeconds ?? info.lastDurationSeconds, dur > 0 {
                let durInt = Int(dur)
                if durInt >= 60 {
                    durText = " (\(durInt / 60)m \(durInt % 60)s)"
                } else {
                    durText = " (\(durInt)s)"
                }
            }
            text = """
            🟢 \(agent.displayName) finished
            Project: \(safeProject)
            New output ready\(durText)
            """
        }

        // 8. Non-blocking asynchronous outbound delivery
        Task { [weak self] in
            guard let self = self else { return }
            let res = try? await self.transport.sendMessage(
                botToken: config.botToken,
                chatId: config.chatId,
                text: text,
                parseMode: nil
            )
            if let res = res {
                self.lastDeliveryResult = res
            }
        }
    }

    public func handleChatGPTMonitorHealthChange(oldHealth: MonitorHealth, newHealth: MonitorHealth) {
        guard ConfigManager.shared.isAgentMonitored(.chatgpt) else { return }
        let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        guard isEnabled else { return }
        let config = EnvConfigLoader.shared.getTelegramConfig()
        guard config.isConfigured else { return }

        guard oldHealth != newHealth else { return }

        let text: String
        if newHealth == .disconnected {
            text = """
            ⚠️ ChatGPT Web monitoring unavailable
            Chrome extension is not connected
            """
        } else if newHealth == .connected && oldHealth == .disconnected {
            text = """
            ✅ ChatGPT Web monitoring restored
            """
        } else {
            return
        }

        let dedupeKey = "chatgpt_monitor_health_\(newHealth.rawValue)"
        lock.lock()
        if lastSentNotificationKeys[dedupeKey] != nil {
            lock.unlock()
            return
        }
        if newHealth == .disconnected {
            lastSentNotificationKeys.removeValue(forKey: "chatgpt_monitor_health_connected")
        } else {
            lastSentNotificationKeys.removeValue(forKey: "chatgpt_monitor_health_disconnected")
        }
        lastSentNotificationKeys[dedupeKey] = Date()
        lock.unlock()

        Task { [weak self] in
            guard let self = self else { return }
            let res = try? await self.transport.sendMessage(
                botToken: config.botToken,
                chatId: config.chatId,
                text: text,
                parseMode: nil
            )
            if let res = res {
                self.lastDeliveryResult = res
            }
        }
    }

    public func handleNetworkHealthChange(isConnected: Bool) {
        let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        guard isEnabled else { return }
        let config = EnvConfigLoader.shared.getTelegramConfig()
        guard config.isConfigured else { return }

        let dedupeKey = "global_network_health_\(isConnected ? "connected" : "disconnected")"
        lock.lock()
        if lastSentNotificationKeys[dedupeKey] != nil {
            lock.unlock()
            return
        }
        if isConnected {
            lastSentNotificationKeys.removeValue(forKey: "global_network_health_disconnected")
        } else {
            lastSentNotificationKeys.removeValue(forKey: "global_network_health_connected")
        }
        lastSentNotificationKeys[dedupeKey] = Date()
        lock.unlock()

        let text = isConnected ? "✅ AgentBridge connection restored" : "🌐 AgentBridge connection unavailable"

        Task { [weak self] in
            guard let self = self else { return }
            let res = try? await self.transport.sendMessage(
                botToken: config.botToken,
                chatId: config.chatId,
                text: text,
                parseMode: nil
            )
            if let res = res {
                self.lastDeliveryResult = res
            }
        }
    }

    public func handleQuotaDepletionChange(agent: AgentID, isExhausted: Bool, resetText: String?) {
        guard ConfigManager.shared.isAgentMonitored(agent) else { return }
        let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
        guard isEnabled else { return }
        let isQuotaAlertsEnabled = ConfigManager.shared.config.isTelegramQuotaAlertsEnabled ?? true
        guard isQuotaAlertsEnabled else { return }
        let config = EnvConfigLoader.shared.getTelegramConfig()
        guard config.isConfigured else { return }

        let dedupeKey = "quota_\(agent.rawValue)_\(isExhausted ? "exhausted" : "restored")"
        lock.lock()
        if lastSentNotificationKeys[dedupeKey] != nil {
            lock.unlock()
            return
        }
        if isExhausted {
            lastSentNotificationKeys.removeValue(forKey: "quota_\(agent.rawValue)_restored")
        } else {
            lastSentNotificationKeys.removeValue(forKey: "quota_\(agent.rawValue)_exhausted")
        }
        lastSentNotificationKeys[dedupeKey] = Date()
        lock.unlock()

        let text: String
        if isExhausted {
            if let r = resetText, !r.isEmpty {
                text = "⛔ \(agent.displayName) quota exhausted\nResets: \(r)"
            } else {
                text = "⛔ \(agent.displayName) quota exhausted"
            }
        } else {
            text = "🥱 \(agent.displayName) quota restored"
        }

        Task { [weak self] in
            guard let self = self else { return }
            let res = try? await self.transport.sendMessage(
                botToken: config.botToken,
                chatId: config.chatId,
                text: text,
                parseMode: nil
            )
            if let res = res {
                self.lastDeliveryResult = res
            }
        }
    }

    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        lastSentNotificationKeys.removeAll()
        activeOverrides.removeAll()
        lastDeliveryResult = nil
        lastUpdateId = 0
        stopPolling()
    }
}
