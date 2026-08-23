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

    public init(transport: TelegramTransportProtocol = URLSessionTelegramTransport()) {
        self.transport = transport
    }

    public func setup() {
        // Register observer on AgentStore for outbound lifecycle alerts
        AgentStore.shared.addObserver(id: "TelegramBridge") { [weak self] agent, oldStatus, newStatus, detail in
            self?.handleAgentStatusChange(agent: agent, oldStatus: oldStatus, newStatus: newStatus, detail: detail)
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

        let testMessage = "✅ AgentSignalBar Telegram alerts connected"
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

        // 5. Deduplication Gate
        let info = AgentStore.shared.getStatus(for: agent)
        let relevantSession = AgentStore.shared.getSessions(for: agent).first(where: { $0.status == newStatus })
        let sessionId = relevantSession?.sessionId ?? "parent"
        let turnId = relevantSession?.turnId ?? "turn"
        let dedupeKey = "\(agent.rawValue)_\(sessionId)_\(turnId)_\(newStatus.rawValue)"

        lock.lock()
        if lastSentNotificationKeys[dedupeKey] != nil {
            lock.unlock()
            return // Suppress duplicate notification for identical turn/state
        }
        lastSentNotificationKeys[dedupeKey] = Date()
        lock.unlock()

        // 6. Format Privacy-Safe Outbound Notification
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

        // 7. Non-blocking asynchronous outbound delivery
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

    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        lastSentNotificationKeys.removeAll()
        lastDeliveryResult = nil
        lastUpdateId = 0
        stopPolling()
    }
}
