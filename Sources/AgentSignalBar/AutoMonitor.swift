import Foundation
import AppKit

public final class AutoMonitor: @unchecked Sendable {
    public static let shared = AutoMonitor()

    private var timer: Timer?
    private var lastClaudeLogSize: UInt64 = 0
    private var lastAntigravityLogSize: UInt64 = 0
    private var lastAntigravityLSLogSize: UInt64 = 0
    private var lastCodexLogSize: UInt64 = 0

    // File Modification Time Caching
    private var lastClaudeTranscriptPath: String?
    private var lastClaudeModDate: Date?
    private var lastAntigravityTranscriptPath: String?
    private var lastAntigravityTranscriptModDate: Date?


    // Non-Overlapping Polling Guard
    private var isCheckInProgress = false
    private let checkLock = NSLock()

    // Anti-flicker Debounce Quiet Window
    private var lastClaudeActivityTime: Date = Date.distantPast
    private var lastAntigravityActivityTime: Date = Date.distantPast
    private var lastCodexActivityTime: Date = Date.distantPast

    // Concurrency Tracking Metrics for Production Testing
    public private(set) var activeCheckCount: Int = 0
    public private(set) var peakConcurrentCheckCount: Int = 0
    public private(set) var rejectedConcurrentCheckCount: Int = 0

    // Poll Body Seam for Unit Testing
    public var pollBodyHandler: (() -> Void)?

    // File Content Read Counter for Testing Unchanged Suppression
    public private(set) var readTailCallCount: Int = 0

    // Cache Decision Seam: Returns true if path or mtime is new/changed, false if suppressed
    public func shouldReadClaudeTranscript(info: ClaudeTranscriptInfo) -> Bool {
        if info.path == lastClaudeTranscriptPath && info.modDate == lastClaudeModDate {
            return false
        }
        lastClaudeTranscriptPath = info.path
        lastClaudeModDate = info.modDate
        return true
    }

    // Unreaped Process Lock & State Tracking
    private let processLock = NSLock()
    public private(set) var unresolvedProcessPID: pid_t? = nil
    public private(set) var lastSubprocessPID: pid_t? = nil
    public private(set) var lastSubprocessConfirmedReaped: Bool = false
    public private(set) var processSpawnBlockedCount: Int = 0

    // Injectable seams for testing timed-out process termination steps
    public var overrideSigtermWaitTimeoutSeconds: TimeInterval? = nil
    public var overrideFinalWaitTimeoutSeconds: TimeInterval? = nil
    public var overrideFinalWaitResult: Bool? = nil

    public func setUnresolvedProcessPIDForTesting(_ pid: pid_t?) {
        processLock.lock()
        unresolvedProcessPID = pid
        processLock.unlock()
    }

    public func resetProcessTracking() {
        processLock.lock()
        unresolvedProcessPID = nil
        lastSubprocessPID = nil
        lastSubprocessConfirmedReaped = false
        processSpawnBlockedCount = 0
        overrideSigtermWaitTimeoutSeconds = nil
        overrideFinalWaitTimeoutSeconds = nil
        overrideFinalWaitResult = nil
        processLock.unlock()
    }

    public func resetTestMetrics() {
        checkLock.lock()
        activeCheckCount = 0
        peakConcurrentCheckCount = 0
        rejectedConcurrentCheckCount = 0
        readTailCallCount = 0
        lastClaudeTranscriptPath = nil
        lastClaudeModDate = nil
        codexRolloutOffsets.removeAll()
        codexPendingLineBuffers.removeAll()
        pollBodyHandler = nil
        checkLock.unlock()
        resetProcessTracking()
    }

    public func resetCodexOffsetsForTesting() {
        checkLock.lock()
        codexRolloutOffsets.removeAll()
        codexPendingLineBuffers.removeAll()
        checkLock.unlock()
    }

    public func setCodexOffsetForTesting(threadId: String, offset: UInt64) {
        checkLock.lock()
        codexRolloutOffsets[threadId] = offset
        checkLock.unlock()
    }

    public func start() {
        NetworkHealthMonitor.shared.start()
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async {
                    self?.checkAllAgents()
                }
            }
        }
        print("🔍 AutoMonitor background watcher active across all 4 agents.")
    }

    public func checkAllAgents() {
        checkLock.lock()
        guard !isCheckInProgress else {
            rejectedConcurrentCheckCount += 1
            checkLock.unlock()
            return
        }
        isCheckInProgress = true
        activeCheckCount += 1
        peakConcurrentCheckCount = max(peakConcurrentCheckCount, activeCheckCount)
        checkLock.unlock()

        defer {
            checkLock.lock()
            activeCheckCount -= 1
            isCheckInProgress = false
            checkLock.unlock()
        }

        if let customHandler = pollBodyHandler {
            customHandler()
            return
        }

        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        AgentStore.shared.checkAutoInspect(frontmostBundleId: frontmostBundleId)

        if ConfigManager.shared.isAgentMonitored(.claude) {
            checkClaudeLog()
        }
        if ConfigManager.shared.isAgentMonitored(.antigravity) {
            checkAntigravityLog()
        }
        if ConfigManager.shared.isAgentMonitored(.codex) {
            checkCodexLogAndProcess()
        }
        if ConfigManager.shared.isAgentMonitored(.copilot) {
            checkCopilotLogAndProcess()
        }
        if ConfigManager.shared.isAgentMonitored(.chatgpt) {
            checkChatGPTExpiry()
        }

        // Real-time usage limit update from structured connectors
        if ConfigManager.shared.isAgentMonitored(.claude) {
            updateClaudeUsage()
        }
        if ConfigManager.shared.isAgentMonitored(.codex) {
            updateCodexUsageFromLocalFiles()
        }
        if ConfigManager.shared.isAgentMonitored(.antigravity) {
            updateAntigravityUsageFromLocalFiles()
        }
        if ConfigManager.shared.isAgentMonitored(.copilot) {
            updateCopilotUsageFromLocalAPI()
        }
    }

    // Helper: Bounded file tail reader (Max 64KB)
    public func readTailOfFile(atPath path: String, maxBytes: UInt64 = 65536) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64, fileSize > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.closeFile() }

        readTailCallCount += 1

        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // Helper: Subprocess execution with bounded timeout, single-waiter reaping, PID verification, and unreaped containment
    public func runProcessWithTimeout(executableURL: URL, arguments: [String], timeoutSeconds: TimeInterval = 1.0) -> String? {
        processLock.lock()
        if let unPID = unresolvedProcessPID {
            // Check if previously unreaped process has now exited
            if unPID > 0 && kill(unPID, 0) != 0 {
                // Previously unreaped process has now exited! Clear unresolved state
                unresolvedProcessPID = nil
            } else {
                // Previously spawned process remains unreaped/unconfirmed! Block new process launch
                processSpawnBlockedCount += 1
                processLock.unlock()
                print("⚠️ Subprocess launch blocked: Previous PID \(unPID) remains unreaped.")
                return nil
            }
        }
        processLock.unlock()

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        let pid = task.processIdentifier
        processLock.lock()
        lastSubprocessPID = pid
        lastSubprocessConfirmedReaped = false
        processLock.unlock()

        let semaphore = DispatchSemaphore(value: 0)

        // SINGLE background exit waiter
        DispatchQueue.global(qos: .utility).async {
            task.waitUntilExit()
            semaphore.signal()
        }

        // 1. Initial bounded wait
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.terminate() // Send SIGTERM

            let sigtermTimeout = overrideSigtermWaitTimeoutSeconds ?? 0.2
            // 2. Bounded wait on the SAME semaphore
            if semaphore.wait(timeout: .now() + sigtermTimeout) == .timedOut {
                if pid > 0 {
                    kill(pid, SIGKILL)
                }

                let finalTimeout = overrideFinalWaitTimeoutSeconds ?? 0.5
                // 3. Final bounded wait on the SAME semaphore with EXPLICIT result handling
                let reapWaitResult = semaphore.wait(timeout: .now() + finalTimeout)
                let reapResult = (overrideFinalWaitResult == false) ? .timedOut : reapWaitResult
                processLock.lock()
                if reapResult == .success {
                    lastSubprocessConfirmedReaped = true
                    unresolvedProcessPID = nil
                    processLock.unlock()
                    print("⚠️ Subprocess \(executableURL.lastPathComponent) (PID \(pid)) timed out after \(timeoutSeconds)s and was confirmed terminated/reaped.")
                } else {
                    lastSubprocessConfirmedReaped = false
                    unresolvedProcessPID = pid
                    processLock.unlock()
                    print("❌ Subprocess \(executableURL.lastPathComponent) (PID \(pid)) failed to exit after SIGKILL (unresolved/unreaped).")
                }
            } else {
                processLock.lock()
                lastSubprocessConfirmedReaped = true
                unresolvedProcessPID = nil
                processLock.unlock()
                print("⚠️ Subprocess \(executableURL.lastPathComponent) (PID \(pid)) timed out after \(timeoutSeconds)s and terminated gracefully upon SIGTERM.")
            }

            return nil
        }


        processLock.lock()
        lastSubprocessConfirmedReaped = true
        unresolvedProcessPID = nil
        processLock.unlock()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }





    private var lastClaudeQuotaFetch: Date = .distantPast
    private var lastAgyQuotaFetch: Date = .distantPast
    private var lastCodexQuotaFetch: Date = .distantPast
    private var lastCopilotQuotaFetch: Date = .distantPast

    public func refreshUsageNow() {
        lastClaudeQuotaFetch = .distantPast
        lastAgyQuotaFetch = .distantPast
        lastCodexQuotaFetch = .distantPast
        lastCopilotQuotaFetch = .distantPast
        updateClaudeUsage(forceRefresh: true)
        updateAntigravityUsageFromLocalFiles()
        updateCodexUsageFromLocalFiles()
        updateCopilotUsageFromLocalAPI()
    }

    // Dynamic Claude Usage Sync from Structured OAuth API, Local History, or CLI Fallback
    private func updateClaudeUsage(forceRefresh: Bool = false) {
        let now = Date()
        if forceRefresh || now.timeIntervalSince(lastClaudeQuotaFetch) >= 10.0 {
            lastClaudeQuotaFetch = now
            if let liveUsage = ClaudeLocalQuotaConnector.shared.fetchQuota(forceRefresh: forceRefresh) {
                var updated = liveUsage
                updated.lastSuccessfulRefresh = now
                AgentUsageStore.shared.updateUsage(for: .claude, data: updated)
                AgentStore.shared.updateAvailability(for: .claude, availability: updated.availability)
                return
            } else {
                if var existing = AgentUsageStore.shared.getUsage(for: .claude), (existing.sessionLimitPercent != nil || existing.weeklyLimitPercent != nil) {
                    existing.isLiveSource = false
                    existing.freshness = "Stale"
                    existing.lastUpdated = now
                    AgentUsageStore.shared.updateUsage(for: .claude, data: existing)
                    return
                }
            }
        }

        // Stale-while-revalidate: if existing live usage exists, preserve it!
        let existing = AgentUsageStore.shared.getUsage(for: .claude)
        if let existing = existing, existing.isLiveSource || existing.sessionLimitPercent != nil || existing.weeklyLimitPercent != nil {
            AgentStore.shared.updateAvailability(for: .claude, availability: existing.availability)
            return
        }
    }

    // Dynamic Antigravity Usage Sync from local language_server Connect RPC
    private func updateAntigravityUsageFromLocalFiles() {
        let now = Date()
        if now.timeIntervalSince(lastAgyQuotaFetch) >= 10.0 {
            lastAgyQuotaFetch = now
            if let liveUsage = AntigravityLocalQuotaConnector.shared.fetchQuota() {
                var updated = liveUsage
                updated.lastSuccessfulRefresh = now
                AgentUsageStore.shared.updateUsage(for: .antigravity, data: updated)
                AgentStore.shared.updateAvailability(for: .antigravity, availability: updated.availability)
                return
            } else {
                // Live fetch failed: preserve prior sample but mark source as not live (last known)
                if var existing = AgentUsageStore.shared.getUsage(for: .antigravity), !existing.modelFamilies.isEmpty {
                    existing.isLiveSource = false
                    existing.freshness = "Stale"
                    existing.lastUpdated = now
                    AgentUsageStore.shared.updateUsage(for: .antigravity, data: existing)
                    return
                }
            }
        }

        // Stale-while-revalidate: if existing live usage exists, preserve it!
        let existing = AgentUsageStore.shared.getUsage(for: .antigravity)
        if let existing = existing, existing.isLiveSource || !existing.modelFamilies.isEmpty {
            AgentStore.shared.updateAvailability(for: .antigravity, availability: existing.availability)
            return
        }

        var usage = existing ?? AgentUsageData(agent: .antigravity)
        usage.sessionLimitPercent = nil
        usage.sessionResetText = nil
        usage.weeklyLimitPercent = nil
        usage.weeklyResetText = nil
        usage.extraMetricText = "Live source unavailable"
        usage.modelFamilies = []
        usage.isPercentUsed = false
        usage.isLiveSource = false
        usage.quotaSource = "none"
        usage.sourceAuthority = "loaded_from_config"
        usage.quotaTimestamp = nil
        usage.parserDecision = "no_live_disk_file"
        usage.freshness = "Unavailable"
        usage.lastUpdated = now
        AgentUsageStore.shared.updateUsage(for: .antigravity, data: usage)
        AgentStore.shared.updateAvailability(for: .antigravity, availability: usage.availability)
    }

    // Dynamic Codex Usage Calculator from codex app-server --stdio
    private func updateCodexUsageFromLocalFiles() {
        let now = Date()
        if now.timeIntervalSince(lastCodexQuotaFetch) >= 30.0 {
            lastCodexQuotaFetch = now
            if let liveUsage = CodexAppServerQuotaConnector.shared.fetchQuota() {
                var updated = liveUsage
                updated.lastSuccessfulRefresh = now
                AgentUsageStore.shared.updateUsage(for: .codex, data: updated)
                AgentStore.shared.updateAvailability(for: .codex, availability: liveUsage.availability)
                return
            } else {
                // Live fetch failed: preserve prior sample but mark source as not live (last known)
                if var existing = AgentUsageStore.shared.getUsage(for: .codex), existing.weeklyLimitPercent != nil {
                    existing.isLiveSource = false
                    existing.freshness = "Stale"
                    existing.lastUpdated = now
                    AgentUsageStore.shared.updateUsage(for: .codex, data: existing)
                    return
                }
            }
        }

        // Stale-while-revalidate: if existing live usage exists, preserve it!
        let existing = AgentUsageStore.shared.getUsage(for: .codex)
        if let existing = existing, existing.isLiveSource || existing.weeklyLimitPercent != nil {
            AgentStore.shared.updateAvailability(for: .codex, availability: existing.availability)
            return
        }

        var usage = existing ?? AgentUsageData(agent: .codex)
        let q = ConfigManager.shared.config.quotas?["codex"]
        usage.weeklyLimitPercent = q?.weeklyPercent
        usage.weeklyResetText = q?.weeklyResetText
        usage.resetCardCount = q?.resetCardCount
        usage.resetCardExpiryText = q?.resetCardExpiryText
        usage.extraMetricText = q?.extraMetricText ?? "Live disk quota unavailable"
        usage.isPercentUsed = q?.isPercentUsed ?? false
        usage.isLiveSource = false
        usage.quotaSource = "none"
        usage.quotaTimestamp = nil
        usage.parserDecision = "no_live_disk_file"
        usage.freshness = "Unavailable"
        usage.lastUpdated = now
        AgentUsageStore.shared.updateUsage(for: .codex, data: usage)
        AgentStore.shared.updateAvailability(for: .codex, availability: usage.availability)
    }

    // Dynamic Copilot Usage Sync from structured /copilot_internal/user API
    private func updateCopilotUsageFromLocalAPI() {
        guard ConfigManager.shared.isAgentMonitored(.copilot) else { return }
        let now = Date()
        if now.timeIntervalSince(lastCopilotQuotaFetch) >= 15.0 {
            lastCopilotQuotaFetch = now
            if let liveUsage = CopilotLocalQuotaConnector.shared.fetchCopilotUsage() {
                var updated = liveUsage
                updated.lastSuccessfulRefresh = now
                AgentUsageStore.shared.updateUsage(for: .copilot, data: updated)
                AgentStore.shared.updateAvailability(for: .copilot, availability: updated.availability)
                return
            } else {
                if var existing = AgentUsageStore.shared.getUsage(for: .copilot), existing.sessionLimitPercent != nil {
                    existing.isLiveSource = false
                    existing.freshness = "Stale"
                    existing.lastUpdated = now
                    AgentUsageStore.shared.updateUsage(for: .copilot, data: existing)
                    return
                }
            }
        }

        let existing = AgentUsageStore.shared.getUsage(for: .copilot)
        if let existing = existing, existing.isLiveSource || existing.sessionLimitPercent != nil {
            AgentStore.shared.updateAvailability(for: .copilot, availability: existing.availability)
            return
        }
    }

    private func parseISO8601Date(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private func parseClaudeLogDate(_ line: String) -> Date? {
        let prefix = String(line.prefix(19))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: prefix)
    }

    public struct ClaudeTranscriptInfo {
        public let path: String
        public let modDate: Date

        public init(path: String, modDate: Date) {
            self.path = path
            self.modDate = modDate
        }
    }

    public func findAllRecentClaudeTranscripts(withinSeconds: TimeInterval = 86400) -> [ClaudeTranscriptInfo] {
        let fm = FileManager.default
        var results: [ClaudeTranscriptInfo] = []
        var seenPaths = Set<String>()

        let historyPath = NSString(string: "~/.claude/history.jsonl").expandingTildeInPath
        if fm.fileExists(atPath: historyPath),
           let content = readTailOfFile(atPath: historyPath, maxBytes: 16384) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for line in lines.reversed() {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sessionId = json["sessionId"] as? String, !sessionId.isEmpty,
                   let projectPath = json["project"] as? String, !projectPath.isEmpty {

                    let sanitizedFolder = projectPath.replacingOccurrences(of: "/", with: "-")
                    let transcriptPath = NSString(string: "~/.claude/projects/\(sanitizedFolder)/\(sessionId).jsonl").expandingTildeInPath

                    if !seenPaths.contains(transcriptPath), fm.fileExists(atPath: transcriptPath),
                       let attrs = try? fm.attributesOfItem(atPath: transcriptPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        if Date().timeIntervalSince(modDate) <= withinSeconds {
                            seenPaths.insert(transcriptPath)
                            results.append(ClaudeTranscriptInfo(path: transcriptPath, modDate: modDate))
                        }
                    }
                }
            }
        }

        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
        if let enumerator = fm.enumerator(atPath: projectsDir) {
            while let file = enumerator.nextObject() as? String {
                if file.hasSuffix(".jsonl") {
                    let fullPath = (projectsDir as NSString).appendingPathComponent(file)
                    if !seenPaths.contains(fullPath), let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        if Date().timeIntervalSince(modDate) <= withinSeconds {
                            seenPaths.insert(fullPath)
                            results.append(ClaudeTranscriptInfo(path: fullPath, modDate: modDate))
                        }
                    }
                }
            }
        }

        results.sort(by: { $0.modDate > $1.modDate })
        return Array(results.prefix(5))
    }

    public func findActiveClaudeTranscriptInfo() -> ClaudeTranscriptInfo? {
        return findAllRecentClaudeTranscripts().first
    }

    // 1. Claude Process Watcher (Session automation disabled for baseline recovery)
    public func checkClaudeLog() {
        let workspace = NSWorkspace.shared
        let isAppRunning = workspace.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop" ||
            $0.localizedName?.lowercased() == "claude" ||
            $0.localizedName?.lowercased() == "claude code" ||
            $0.bundleIdentifier == "com.microsoft.VSCode" ||
            $0.bundleIdentifier == "com.googlecode.iterm2" ||
            $0.bundleIdentifier == "com.apple.Terminal" ||
            $0.bundleIdentifier == "com.mitchellh.ghostty" ||
            $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
        })

        let currentClaudeSessions = AgentStore.shared.getSessions(for: .claude)
        let hasActiveTrackedSessions = !currentClaudeSessions.isEmpty

        guard isAppRunning || hasActiveTrackedSessions else {
            AgentStore.shared.updateStatus(for: .claude, status: .off, detail: "Claude Code closed")
            AgentStore.shared.syncSessions(for: .claude, activeSessions: [], processRunning: false)
            return
        }

        reconcileDeadClaudeSessions()
        AgentStore.shared.pruneStaleClaudeSessions()

        let refreshedClaudeSessions = AgentStore.shared.getSessions(for: .claude)
        if refreshedClaudeSessions.isEmpty {
            AgentStore.shared.updateStatus(for: .claude, status: .idle, detail: "Monitoring via Claude Native Hooks (Ready)")
            AgentStore.shared.syncSessions(for: .claude, activeSessions: [], processRunning: true)
        }
    }

    // Check if any tracked Claude CLI session's process has terminated via OS process liveness
    public func reconcileDeadClaudeSessions(sessionsDir: String = ("~/.claude/sessions" as NSString).expandingTildeInPath) {
        guard FileManager.default.fileExists(atPath: sessionsDir) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return }

        var pidSessionMap: [String: pid_t] = [:]
        for file in files where file.hasSuffix(".json") {
            let fullPath = "\(sessionsDir)/\(file)"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pidNum = json["pid"] as? Int,
               let sessId = json["sessionId"] as? String {
                pidSessionMap[sessId] = pid_t(pidNum)
            }
        }

        let claudeSessions = AgentStore.shared.getSessions(for: .claude)
        for session in claudeSessions {
            if let pid = pidSessionMap[session.sessionId] {
                if kill(pid, 0) != 0 {
                    // Process is confirmed dead (ESRCH); transition to idle/remove
                    _ = AgentStore.shared.handleClaudeHookEvent(
                        json: [
                            "event": "SessionEnd",
                            "session_id": session.sessionId,
                            "reason": "Process exited"
                        ],
                        isTestMode: AgentStore.isSyntheticTestSessionId(session.sessionId)
                    )
                }
            }
        }
    }

    // 2. Antigravity Process Watcher (Provider-Native Lifecycle Hooks & Native Transcript Probe)
    public func scanActiveAntigravityTranscript(brainDir: String = ("~/.gemini/antigravity/brain" as NSString).expandingTildeInPath) -> (sessionId: String, title: String, status: AgentStatus, reason: String?, duration: Double?)? {
        guard FileManager.default.fileExists(atPath: brainDir) else { return nil }
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: brainDir) else { return nil }

        // Find newest user-facing conversation directory
        var newestDir: (path: String, modDate: Date, id: String)? = nil
        let now = Date()

        for dir in subdirs {
            guard dir.count == 36, dir.contains("-") else { continue } // Standard UUID format
            guard AgentStore.isUserFacingAntigravitySession(dir) else { continue }
            let dirPath = "\(brainDir)/\(dir)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: dirPath),
                  let mod = attrs[.modificationDate] as? Date else { continue }

            if newestDir == nil || mod > newestDir!.modDate {
                newestDir = (dirPath, mod, dir)
            }
        }

        guard let active = newestDir else { return nil }
        // If the newest conversation is older than 2 hours and not recently modified, return nil
        if now.timeIntervalSince(active.modDate) > 7200 { return nil }

        let transcriptPath = "\(active.path)/.system_generated/logs/transcript.jsonl"
        guard FileManager.default.fileExists(atPath: transcriptPath),
              let transcriptData = readTailOfFile(atPath: transcriptPath, maxBytes: 32768) else {
            return nil
        }

        let lines = transcriptData.components(separatedBy: CharacterSet.newlines).filter { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }
        guard let lastLine = lines.last else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any] else {
            return nil
        }

        let stepType = json["type"] as? String ?? ""
        let toolCalls = json["tool_calls"] as? [[String: Any]]

        let folderName = (active.path as NSString).lastPathComponent
        let title = "[\(folderName.prefix(8))]"

        if stepType == "PLANNER_RESPONSE" {
            if let tools = toolCalls, !tools.isEmpty {
                // Check if tool is ask_question or permission gate
                let hasAskQuestion = tools.contains { t in
                    (t["name"] as? String) == "ask_question"
                }
                if hasAskQuestion {
                    return (active.id, title, .blocked, "Permission / Question gate (ask_question)", nil)
                }
                let timeSinceMod = now.timeIntervalSince(active.modDate)
                if timeSinceMod > 20.0 {
                    let firstTool = tools.first
                    let toolName = (firstTool?["name"] as? String) ?? "Action"
                    return (active.id, title, .blocked, "Permission approval required (\(toolName))", nil)
                } else {
                    return (active.id, title, .working, nil, nil)
                }
            } else {
                let timeSinceMod = now.timeIntervalSince(active.modDate)
                if timeSinceMod < 120.0 {
                    return (active.id, title, .done, nil, timeSinceMod)
                } else {
                    return (active.id, title, .idle, nil, nil)
                }
            }
        } else if stepType == "USER_INPUT" {
            return (active.id, title, .working, nil, nil)
        } else if stepType == "GENERIC" {
            let timeSinceMod = now.timeIntervalSince(active.modDate)
            if timeSinceMod < 60.0 {
                return (active.id, title, .working, nil, nil)
            }
        }

        return nil
    }

    private func checkAntigravityLog() {
        let workspace = NSWorkspace.shared
        let isAppRunning = workspace.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.google.antigravity" ||
            $0.localizedName?.lowercased() == "antigravity" ||
            $0.bundleIdentifier == "com.google.Antigravity"
        })

        guard isAppRunning else {
            AgentStore.shared.updateStatus(for: .antigravity, status: .off, detail: "Antigravity closed")
            AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [], processRunning: false)
            return
        }

        AgentStore.shared.reconcileAntigravitySessions()
        checkAntigravityNotificationCenterBanner()

        let currentAntigravitySessions = AgentStore.shared.getSessions(for: .antigravity)
        if currentAntigravitySessions.isEmpty {
            if let diskSession = scanActiveAntigravityTranscript() {
                let sess = AgentSessionInfo(
                    provider: .antigravity,
                    sessionId: diskSession.sessionId,
                    title: diskSession.title,
                    status: diskSession.status,
                    attentionReason: diskSession.reason,
                    lastDurationSeconds: diskSession.duration,
                    sourceEvidence: "Antigravity Native Transcript Probe"
                )
                AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)
                AgentStore.shared.updateStatus(for: .antigravity, status: diskSession.status, detail: diskSession.reason ?? "Monitoring via Antigravity Native Probe")
            } else {
                AgentStore.shared.updateStatus(for: .antigravity, status: .idle, detail: "Monitoring via Antigravity Native Hooks (Ready)")
                AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
            }
        }
    }

    // Bounded macOS Notification Center AX Probe for Antigravity Permission Notifications
    private func checkAntigravityNotificationCenterBanner() {
        let workspace = NSWorkspace.shared
        guard let ncApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui" || ($0.localizedName ?? "").lowercased().contains("notification center")
        }) else {
            return
        }

        let appRef = AXUIElementCreateApplication(ncApp.processIdentifier)
        if let bannerText = findAntigravityPermissionBannerText(element: appRef) {
            AgentStore.shared.updateAntigravityPermissionFromNotification(reason: bannerText)
        }
    }

    private func findAntigravityPermissionBannerText(element: AXUIElement, depth: Int = 0, maxDepth: Int = 6) -> String? {
        if depth > maxDepth { return nil }

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
           let subrole = value as? String, subrole == "AXNotificationCenterBanner" {

            var titleStr = ""
            var bodyStr = ""
            var descStr = ""
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success,
               let desc = value as? String {
                descStr = desc
            }

            var childrenVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
               let children = childrenVal as? [AXUIElement] {
                for child in children {
                    var idVal: CFTypeRef?
                    var textVal: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(child, "AXIdentifier" as CFString, &idVal)
                    _ = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &textVal)
                    let cId = idVal as? String ?? ""
                    let cText = textVal as? String ?? ""
                    if cId == "title" { titleStr = cText }
                    else if cId == "body" { bodyStr = cText }
                }
            }

            let combined = "\(titleStr) \(bodyStr) \(descStr)".lowercased()
            let isAntigravity = titleStr.lowercased() == "antigravity" ||
                                titleStr.lowercased().contains("antigravity") ||
                                descStr.lowercased().contains("antigravity") ||
                                combined.contains("antigravity") ||
                                combined.contains("terminal")
            if isAntigravity {
                return bodyStr.isEmpty ? (titleStr.isEmpty ? "Antigravity prompt" : titleStr) : bodyStr
            }
        }

        var childrenVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children {
                if let found = findAntigravityPermissionBannerText(element: child, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }
        return nil
    }

    public struct CodexSessionInfo {
        public let path: String
        public let modDate: Date

        public init(path: String, modDate: Date) {
            self.path = path
            self.modDate = modDate
        }
    }

    public struct CodexThreadInfo {
        public let id: String
        public let title: String
        public let rolloutPath: String
        public let cwd: String
        public let updatedAtMs: Int64

        public init(id: String, title: String, rolloutPath: String, cwd: String = "", updatedAtMs: Int64 = 0) {
            self.id = id
            self.title = title
            self.rolloutPath = rolloutPath
            self.cwd = cwd
            self.updatedAtMs = updatedAtMs
        }
    }

    // Codex Incremental Rollout Tracking Offsets and Partial-Line Buffers
    public private(set) var codexRolloutOffsets: [String: UInt64] = [:]
    public private(set) var codexPendingLineBuffers: [String: String] = [:]

    public static func isSafeSessionTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count > 60 { return false }
        if trimmed.contains("\n") || trimmed.contains("\r") { return false }
        if trimmed.hasPrefix("#") { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return false }
        let lower = trimmed.lowercased()
        if lower.contains("files pasted") || lower.contains("pasted-text") || lower.contains("pasted text") { return false }
        if lower.contains("select ") || lower.contains("insert ") || lower.contains("delete from") || lower.contains("update ") { return false }
        if lower.contains("import ") || lower.contains("function ") || lower.contains("const ") || lower.contains("let ") || lower.contains("def ") || lower.contains("class ") { return false }
        if trimmed.contains("{") || trimmed.contains("}") || trimmed.contains(";") { return false }
        return true
    }

    public static func resolveCodexSessionTitle(name: String, title: String, cwd: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && isSafeSessionTitle(trimmedName) {
            return trimmedName
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && isSafeSessionTitle(trimmedTitle) {
            return trimmedTitle
        }
        let folder = (cwd as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty && isSafeSessionTitle(folder) {
            return folder
        }
        return "Codex Session"
    }

    public func fetchCodexThreads(limit: Int = 15) -> [CodexThreadInfo] {
        let fm = FileManager.default
        let dbPath = NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
        let catalogDbPath = NSString(string: "~/.codex/sqlite/codex-dev.db").expandingTildeInPath

        guard fm.fileExists(atPath: dbPath) else {
            return []
        }

        // 1. Fetch display titles from local_thread_catalog in codex-dev.db if available
        var catalogTitles: [String: String] = [:]
        if fm.fileExists(atPath: catalogDbPath) {
            let catQuery = "SELECT thread_id, display_title FROM local_thread_catalog WHERE host_id='local' AND missing_candidate=0;"
            if let catOutput = runProcessWithTimeout(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-json", catalogDbPath, catQuery],
                timeoutSeconds: 1.0
            ), let catData = catOutput.data(using: .utf8),
               let catArray = try? JSONSerialization.jsonObject(with: catData) as? [[String: Any]] {
                for dict in catArray {
                    if let tid = dict["thread_id"] as? String, !tid.isEmpty,
                       let title = dict["display_title"] as? String, !title.isEmpty {
                        catalogTitles[tid] = title
                    }
                }
            }
        }

        // 2. Fetch active threads from state_5.sqlite
        var results: [CodexThreadInfo] = []
        var seenIds = Set<String>()

        let query = "SELECT id, COALESCE(NULLIF(name, ''), '') AS name, COALESCE(NULLIF(title, ''), '') AS title, rollout_path, cwd, updated_at_ms FROM threads WHERE archived=0 AND COALESCE(thread_source, 'user') != 'subagent' ORDER BY updated_at_ms DESC LIMIT \(limit);"
        if let output = runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-json", dbPath, query],
            timeoutSeconds: 1.0
        ), let data = output.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in array {
                guard let tid = dict["id"] as? String, !tid.isEmpty,
                      let path = dict["rollout_path"] as? String, !path.isEmpty,
                      fm.fileExists(atPath: path),
                      !seenIds.contains(tid) else { continue }
                seenIds.insert(tid)
                let rawName = dict["name"] as? String ?? ""
                let rawTitle = dict["title"] as? String ?? ""
                let cwd = dict["cwd"] as? String ?? ""
                let updated = (dict["updated_at_ms"] as? NSNumber)?.int64Value ?? 0

                let resolvedTitle: String
                if let catTitle = catalogTitles[tid], !catTitle.isEmpty && AutoMonitor.isSafeSessionTitle(catTitle) {
                    resolvedTitle = catTitle
                } else {
                    resolvedTitle = AutoMonitor.resolveCodexSessionTitle(name: rawName, title: rawTitle, cwd: cwd)
                }

                results.append(CodexThreadInfo(id: tid, title: resolvedTitle, rolloutPath: path, cwd: cwd, updatedAtMs: updated))
            }
        }

        return results
    }

    public func fetchCodexThreadInfo() -> CodexThreadInfo? {
        return fetchCodexThreads(limit: 1).first
    }

    public func findActiveCodexSessionInfo() -> CodexSessionInfo? {
        if let info = fetchCodexThreadInfo() {
            return CodexSessionInfo(path: info.rolloutPath, modDate: Date(timeIntervalSince1970: Double(info.updatedAtMs) / 1000.0))
        }
        return nil
    }

    public struct CodexHistoryTurnInfo {
        public let threadId: String
        public let turnId: String
        public let status: String // "inProgress", "completed", "failed"
        public let startedAt: Int64
        public let completedAt: Int64?
        public let durationMs: Double?

        public init(threadId: String, turnId: String, status: String, startedAt: Int64, completedAt: Int64? = nil, durationMs: Double? = nil) {
            self.threadId = threadId
            self.turnId = turnId
            self.status = status
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
        }
    }

    public func fetchCodexHistoryTurns(limit: Int = 20) -> [String: CodexHistoryTurnInfo] {
        let dbPath = NSString(string: "~/.codex/thread_history_1.sqlite").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var turns: [String: CodexHistoryTurnInfo] = [:]
        let query = "SELECT thread_id, turn_id, status, started_at, completed_at, duration_ms FROM thread_turns ORDER BY started_at DESC LIMIT \(limit);"
        if let output = runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-json", dbPath, query],
            timeoutSeconds: 1.0
        ), let data = output.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in array {
                guard let tid = dict["thread_id"] as? String, !tid.isEmpty, turns[tid] == nil,
                      let turnId = dict["turn_id"] as? String, !turnId.isEmpty,
                      let status = dict["status"] as? String, !status.isEmpty else { continue }
                let startedAt = (dict["started_at"] as? NSNumber)?.int64Value ?? 0
                let compVal = (dict["completed_at"] as? NSNumber)?.int64Value
                let durVal = (dict["duration_ms"] as? NSNumber)?.doubleValue
                turns[tid] = CodexHistoryTurnInfo(
                    threadId: tid,
                    turnId: turnId,
                    status: status,
                    startedAt: startedAt,
                    completedAt: (compVal != nil && compVal! > 0) ? compVal : nil,
                    durationMs: (durVal != nil && durVal! > 0) ? durVal : nil
                )
            }
        }
        return turns
    }

    // Helper: Incremental Rollout Stream Parser for Codex Parent Turns
    public func processCodexRollout(thread: CodexThreadInfo) {
        let fm = FileManager.default
        let path = thread.rolloutPath
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64 else {
            return
        }

        var lastOffset = codexRolloutOffsets[thread.id]
        if lastOffset == nil {
            lastOffset = 0
        }

        guard fileSize > lastOffset! else {
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.closeFile() }

        handle.seek(toFileOffset: lastOffset!)
        let newData = handle.readDataToEndOfFile()
        codexRolloutOffsets[thread.id] = fileSize

        guard let text = String(data: newData, encoding: .utf8), !text.isEmpty else { return }

        let existingBuffer = codexPendingLineBuffers[thread.id] ?? ""
        let combined = existingBuffer + text
        let lines = combined.components(separatedBy: "\n")

        if combined.hasSuffix("\n") {
            codexPendingLineBuffers[thread.id] = ""
        } else if let last = lines.last {
            codexPendingLineBuffers[thread.id] = last
        }

        let completeLines = combined.hasSuffix("\n") ? lines : Array(lines.dropLast())

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let payload = json["payload"] as? [String: Any]
            let topType = json["type"] as? String
            let payloadType = payload?["type"] as? String ?? topType
            let role = payload?["role"] as? String
            let passthrough = payload?["internal_chat_message_metadata_passthrough"] as? [String: Any]
            let passthroughTurnId = passthrough?["turn_id"] as? String
            let turnId = (payload?["turn_id"] as? String) ?? (json["turn_id"] as? String) ?? passthroughTurnId
            let durationMs = payload?["duration_ms"] as? Double

            if payloadType == "task_started" || payloadType == "turn_started" {
                _ = AgentStore.shared.handleCodexRolloutEvent(
                    threadId: thread.id,
                    title: thread.title,
                    cwd: thread.cwd,
                    rolloutPath: thread.rolloutPath,
                    eventType: "task_started",
                    turnId: turnId,
                    durationMs: nil
                )
            } else if payloadType == "task_complete" || payloadType == "turn_complete" {
                _ = AgentStore.shared.handleCodexRolloutEvent(
                    threadId: thread.id,
                    title: thread.title,
                    cwd: thread.cwd,
                    rolloutPath: thread.rolloutPath,
                    eventType: "task_complete",
                    turnId: turnId,
                    durationMs: durationMs
                )
            } else if payloadType == "message" {
                // User prompt or assistant message starts/continues turn
                _ = AgentStore.shared.handleCodexRolloutEvent(
                    threadId: thread.id,
                    title: thread.title,
                    cwd: thread.cwd,
                    rolloutPath: thread.rolloutPath,
                    eventType: "task_started",
                    turnId: turnId,
                    durationMs: nil
                )
            } else if payloadType == "item_completed" {
                // In current Codex event_msg, item_completed payload carries turn_id and item (Reasoning / tool)
                let item = payload?["item"] as? [String: Any]
                let itemType = item?["type"] as? String
                let itemTurnId = item?["turn_id"] as? String
                let resolvedTurnId = turnId ?? itemTurnId
                if itemType == "Reasoning" || itemType == "custom_tool_call" || itemType == "CommandExecution" || itemType == "Text" || itemType == "UserMessage" || itemType == "AgentMessage" {
                    _ = AgentStore.shared.handleCodexRolloutEvent(
                        threadId: thread.id,
                        title: thread.title,
                        cwd: thread.cwd,
                        rolloutPath: thread.rolloutPath,
                        eventType: "task_started",
                        turnId: resolvedTurnId,
                        durationMs: nil
                    )
                }
            } else if payloadType == "reasoning" || payloadType == "custom_tool_call" || payloadType == "custom_tool_call_output" {
                // Active reasoning / tool execution in progress
                _ = AgentStore.shared.handleCodexRolloutEvent(
                    threadId: thread.id,
                    title: thread.title,
                    cwd: thread.cwd,
                    rolloutPath: thread.rolloutPath,
                    eventType: "task_started",
                    turnId: turnId,
                    durationMs: nil
                )
            }
        }
    }

    // 3. Codex Process & Rollout Watcher (Parent Rollout Event Truth)
    private func checkCodexLogAndProcess() {
        let workspace = NSWorkspace.shared
        let codexApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex" ||
            $0.localizedName?.lowercased() == "codex" ||
            $0.localizedName?.lowercased() == "chatgpt"
        })

        guard codexApp != nil else {
            AgentStore.shared.setMonitorHealth(for: .codex, health: .connected)
            AgentStore.shared.updateStatus(for: .codex, status: .off, detail: "Codex Desktop closed")
            AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: false)
            return
        }

        let dbPath = NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            // Codex app is running, but state database is missing
            AgentStore.shared.setMonitorHealth(for: .codex, health: .disconnected)
            AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Codex database unavailable")
            AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)
            return
        }

        let historyTurns = fetchCodexHistoryTurns(limit: 20)
        let threads = fetchCodexThreads(limit: 15)

        if threads.isEmpty {
            // Probe if sqlite query succeeded or failed
            let probeQuery = "SELECT COUNT(*) FROM threads;"
            let probeOutput = runProcessWithTimeout(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [dbPath, probeQuery],
                timeoutSeconds: 1.0
            )
            if probeOutput == nil {
                // SQLite query failed/timeout -> corrupted or inaccessible database
                AgentStore.shared.setMonitorHealth(for: .codex, health: .disconnected)
                AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Codex database unparseable")
                AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)
                return
            }
        }

        // Database is healthy and parseable
        AgentStore.shared.setMonitorHealth(for: .codex, health: .connected)

        let validThreadIds = Set(threads.map { $0.id })

        // 1. Authoritative Multi-Session Reconciliation: Purge obsolete threads & reconcile completed turns
        AgentStore.shared.reconcileCodexSessions(validThreadIds: validThreadIds, historyTurns: historyTurns)

        for thread in threads {
            // First check if thread_history_1.sqlite explicitly reports this thread's turn
            if let turn = historyTurns[thread.id] {
                if turn.status == "inProgress" {
                    let start = Date(timeIntervalSince1970: Double(turn.startedAt))
                    _ = AgentStore.shared.handleCodexTurnState(
                        threadId: thread.id,
                        title: thread.title,
                        cwd: thread.cwd,
                        rolloutPath: thread.rolloutPath,
                        status: .working,
                        turnId: turn.turnId,
                        thinkingStartTime: start,
                        durationMs: nil
                    )
                }
            }

            // Incremental rollout stream processing
            if codexRolloutOffsets[thread.id] == nil {
                // First time seeing this thread in monitor:
                // If it is already marked completed or failed in history, fast-forward baseline to avoid historical replay on startup/restart
                if let turn = historyTurns[thread.id], turn.status == "completed" || turn.status == "failed" {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: thread.rolloutPath),
                       let size = attrs[.size] as? UInt64 {
                        codexRolloutOffsets[thread.id] = size
                    }
                } else {
                    // Newly discovered thread in progress or fresh live thread: process rollout from 0 to capture task_started
                    processCodexRollout(thread: thread)
                }
            } else {
                // Incrementally process rollout file for live events
                processCodexRollout(thread: thread)
            }
        }

        AgentStore.shared.pruneStaleCodexSessions()

        let currentCodexSessions = AgentStore.shared.getSessions(for: .codex)
        if currentCodexSessions.isEmpty {
            let currentStatus = AgentStore.shared.getStatus(for: .codex).status
            if currentStatus != .idle && currentStatus != .off {
                AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Codex Desktop ready")
            }
        }
    }

    // 4. GitHub Copilot Process & Events Watcher
    public struct CopilotSessionSummary {
        public let id: String
        public let title: String
        public let cwd: String
        public let eventsPath: String
        public let modDate: Date

        public init(id: String, title: String, cwd: String, eventsPath: String, modDate: Date) {
            self.id = id
            self.title = title
            self.cwd = cwd
            self.eventsPath = eventsPath
            self.modDate = modDate
        }
    }

    public private(set) var copilotEventsOffsets: [String: UInt64] = [:]
    public private(set) var copilotPendingLineBuffers: [String: String] = [:]

    public func fetchCopilotSessions(limit: Int = 10) -> [CopilotSessionSummary] {
        let fm = FileManager.default
        let sessionStateDir = NSString(string: "~/.copilot/session-state").expandingTildeInPath
        let sessionStoreDbPath = NSString(string: "~/.copilot/session-store.db").expandingTildeInPath

        var results: [CopilotSessionSummary] = []
        var dbTitles: [String: (title: String, cwd: String)] = [:]

        // Query session-store.db for titles & cwds if available
        if fm.fileExists(atPath: sessionStoreDbPath) {
            let query = "SELECT id, COALESCE(summary, '') AS summary, COALESCE(cwd, '') AS cwd FROM sessions ORDER BY updated_at DESC LIMIT 20;"
            if let output = runProcessWithTimeout(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: ["-json", sessionStoreDbPath, query],
                timeoutSeconds: 1.0
            ), let data = output.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for dict in array {
                    if let id = dict["id"] as? String, !id.isEmpty {
                        let summary = dict["summary"] as? String ?? ""
                        let cwd = dict["cwd"] as? String ?? ""
                        dbTitles[id] = (title: summary, cwd: cwd)
                    }
                }
            }
        }

        // Scan session-state directory
        if let subdirs = try? fm.contentsOfDirectory(atPath: sessionStateDir) {
            for subdir in subdirs {
                if subdir.hasPrefix("pending-session:") || subdir.hasPrefix("optimistic-chat-") {
                    // Skip drafts without finalized session state
                    continue
                }
                let fullDirPath = (sessionStateDir as NSString).appendingPathComponent(subdir)
                let eventsPath = (fullDirPath as NSString).appendingPathComponent("events.jsonl")
                let workspaceYamlPath = (fullDirPath as NSString).appendingPathComponent("workspace.yaml")

                guard fm.fileExists(atPath: eventsPath),
                      let attrs = try? fm.attributesOfItem(atPath: eventsPath),
                      let modDate = attrs[.modificationDate] as? Date else {
                    continue
                }

                var title = dbTitles[subdir]?.title ?? ""
                var cwd = dbTitles[subdir]?.cwd ?? ""

                // Check workspace.yaml for title if missing
                if title.isEmpty, fm.fileExists(atPath: workspaceYamlPath),
                   let yamlContent = try? String(contentsOfFile: workspaceYamlPath, encoding: .utf8) {
                    for yLine in yamlContent.components(separatedBy: "\n") {
                        if yLine.hasPrefix("name:") {
                            title = yLine.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if yLine.hasPrefix("cwd:") {
                            cwd = yLine.replacingOccurrences(of: "cwd:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }

                if title.isEmpty {
                    let folderName = (cwd as NSString).lastPathComponent
                    title = folderName.isEmpty ? "Copilot Session (\(subdir.prefix(8)))" : "[\(folderName)]"
                }

                results.append(CopilotSessionSummary(id: subdir, title: title, cwd: cwd, eventsPath: eventsPath, modDate: modDate))
            }
        }

        results.sort(by: { $0.modDate > $1.modDate })
        return Array(results.prefix(limit))
    }

    public func processCopilotEvents(session: CopilotSessionSummary) {
        let fm = FileManager.default
        let path = session.eventsPath
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64 else {
            return
        }

        var lastOffset = copilotEventsOffsets[session.id]
        if lastOffset == nil {
            let startOffset = fileSize > 65536 ? fileSize - 65536 : 0
            lastOffset = startOffset
        }

        guard fileSize > lastOffset! else {
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.closeFile() }

        handle.seek(toFileOffset: lastOffset!)
        let newData = handle.readDataToEndOfFile()
        copilotEventsOffsets[session.id] = fileSize

        guard let text = String(data: newData, encoding: .utf8), !text.isEmpty else { return }

        let existingBuffer = copilotPendingLineBuffers[session.id] ?? ""
        let combined = existingBuffer + text
        let lines = combined.components(separatedBy: "\n")

        if combined.hasSuffix("\n") {
            copilotPendingLineBuffers[session.id] = ""
        } else if let last = lines.last {
            copilotPendingLineBuffers[session.id] = last
        }

        let completeLines = combined.hasSuffix("\n") ? lines : Array(lines.dropLast())

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else {
                continue
            }

            let dataObj = json["data"] as? [String: Any] ?? [:]
            let turnId = dataObj["turnId"] as? String
            let toolName = dataObj["toolName"] as? String
            let hookType = dataObj["hookType"] as? String ?? json["hookType"] as? String
            let durationMs = dataObj["durationMs"] as? Double ?? (dataObj["durationMs"] as? Int).map { Double($0) }

            _ = AgentStore.shared.handleCopilotEvent(
                sessionId: session.id,
                title: session.title,
                cwd: session.cwd,
                eventType: eventType,
                hookType: hookType,
                toolName: toolName,
                turnId: turnId,
                durationMs: durationMs
            )
        }
    }

    public func checkCopilotLogAndProcess() {
        let workspace = NSWorkspace.shared
        let copilotApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.github.githubapp" ||
            $0.localizedName?.lowercased() == "github" ||
            $0.localizedName?.lowercased() == "github copilot" ||
            $0.bundleIdentifier == "com.microsoft.VSCode" ||
            $0.localizedName?.lowercased() == "code"
        })

        guard copilotApp != nil else {
            AgentStore.shared.updateStatus(for: .copilot, status: .off, detail: "GitHub Copilot closed")
            AgentStore.shared.syncSessions(for: .copilot, activeSessions: [], processRunning: false)
            return
        }

        let sessions = fetchCopilotSessions(limit: 10)
        for s in sessions {
            processCopilotEvents(session: s)
        }

        AgentStore.shared.pruneStaleCopilotSessions()

        let currentCopilotSessions = AgentStore.shared.getSessions(for: .copilot)
        if currentCopilotSessions.isEmpty {
            AgentStore.shared.updateStatus(for: .copilot, status: .idle, detail: "GitHub Copilot ready")
            AgentStore.shared.syncSessions(for: .copilot, activeSessions: [], processRunning: true)
        }
    }

    // 5. ChatGPT Expiry & Monitor Health check
    private func checkChatGPTExpiry() {
        let workspace = NSWorkspace.shared
        let isChromeRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" || $0.localizedName == "Google Chrome" })
        let isMonitored = ConfigManager.shared.isAgentMonitored(.chatgpt)

        if !isChromeRunning {
            let current = AgentStore.shared.getStatus(for: .chatgpt)
            if current.status != .off {
                AgentStore.shared.updateStatus(for: .chatgpt, status: .off, detail: "Google Chrome closed")
            }
            AgentStore.shared.setChatGPTMonitorHealth(.connected)
        } else if isMonitored {
            let health = AgentStore.shared.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true)
            let current = AgentStore.shared.getStatus(for: .chatgpt)

            if current.status == .off {
                AgentStore.shared.updateStatus(for: .chatgpt, status: .idle, detail: "Google Chrome running")
            }

            AgentStore.shared.setChatGPTMonitorHealth(health)
        }
    }
}

// MARK: - Antigravity Local Language Server Connect RPC Quota Connector
public final class AntigravityLocalQuotaConnector: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = AntigravityLocalQuotaConnector()

    private override init() {
        super.init()
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public struct LanguageServerProcessInfo: Sendable {
        public let pid: Int32
        public let csrfToken: String?
    }

    public func detectLanguageServerProcess() -> LanguageServerProcessInfo? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: "\n") {
                let lower = line.lowercased()
                if lower.contains("antigravity") && (lower.contains("language_server") || lower.contains("--csrf_token")) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
                    let cmdLine = String(parts[1])
                    var token: String? = nil
                    if let range = cmdLine.range(of: "--csrf_token=") {
                        let sub = cmdLine[range.upperBound...]
                        token = String(sub.prefix(while: { $0 != " " && $0 != "\"" && $0 != "'" }))
                    } else if let range = cmdLine.range(of: "--csrf_token ") {
                        let sub = cmdLine[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        token = String(sub.prefix(while: { $0 != " " && $0 != "\"" && $0 != "'" }))
                    }
                    return LanguageServerProcessInfo(pid: pid, csrfToken: token)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    public func discoverListeningPorts(pid: Int32) -> [Int] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            var ports: [Int] = []
            for line in output.components(separatedBy: "\n") {
                if let range = line.range(of: ":") {
                    let sub = line[range.upperBound...]
                    let portStr = String(sub.prefix(while: { $0.isNumber }))
                    if let port = Int(portStr), !ports.contains(port) {
                        ports.append(port)
                    }
                }
            }
            return ports
        } catch {
            return []
        }
    }

    public func fetchQuota() -> AgentUsageData? {
        guard let proc = detectLanguageServerProcess() else { return nil }
        let ports = discoverListeningPorts(pid: proc.pid)
        guard !ports.isEmpty else { return nil }

        for port in ports {
            // 1. First attempt first-party RetrieveUserQuotaSummary Connect-RPC
            if let usage = queryRetrieveUserQuotaSummary(port: port, csrfToken: proc.csrfToken) {
                return usage
            }
            // 2. Fallback to GetUserStatus Connect-RPC
            if let usage = queryGetUserStatus(port: port, csrfToken: proc.csrfToken) {
                return usage
            }
        }
        return nil
    }

    public func queryRetrieveUserQuotaSummary(port: Int, csrfToken: String?) -> AgentUsageData? {
        guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = csrfToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        req.httpBody = "{\"forceRefresh\":true}".data(using: .utf8)

        let sema = DispatchSemaphore(value: 0)
        var fetchedData: Data? = nil

        session.dataTask(with: req) { data, resp, err in
            if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200, let data = data {
                fetchedData = data
            }
            sema.signal()
        }.resume()

        _ = sema.wait(timeout: .now() + 1.5)
        session.finishTasksAndInvalidate()

        guard let data = fetchedData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseAntigravityUserQuotaSummaryJSON(json)
    }

    public func parseAntigravityUserQuotaSummaryJSON(_ json: [String: Any]) -> AgentUsageData? {
        let resp = (json["response"] as? [String: Any]) ?? json
        let groups = (resp["groups"] as? [[String: Any]]) ?? []
        if groups.isEmpty { return nil }

        var families: [ModelFamilyQuota] = []

        for g in groups {
            let gName = (g["displayName"] as? String) ?? ""
            let lowerName = gName.lowercased()
            let familyName: String
            if lowerName.contains("gemini") {
                familyName = "Gemini"
            } else if lowerName.contains("claude") || lowerName.contains("gpt") || lowerName.contains("3p") {
                familyName = "Claude/GPT"
            } else {
                familyName = gName
            }

            var sPct: Double? = nil
            var sReset: String? = nil
            var wPct: Double? = nil
            var wReset: String? = nil

            let buckets = (g["buckets"] as? [[String: Any]]) ?? []
            for b in buckets {
                let bId = ((b["bucketId"] as? String) ?? "").lowercased()
                let bWindow = ((b["window"] as? String) ?? "").lowercased()
                let bDisplay = ((b["displayName"] as? String) ?? "").lowercased()
                let rem = (b["remainingFraction"] as? NSNumber)?.doubleValue
                let reset = b["resetTime"] as? String

                let is5h = bWindow == "5h" || bId.contains("5h") || bDisplay.contains("five hour")
                let isWeekly = bWindow == "weekly" || bId.contains("weekly") || bDisplay.contains("weekly")

                if is5h {
                    if let rem = rem {
                        sPct = Double(Int(round(rem * 100.0)))
                    }
                    sReset = formatResetText(from: reset)
                } else if isWeekly {
                    if let rem = rem {
                        wPct = Double(Int(round(rem * 100.0)))
                    }
                    wReset = formatResetText(from: reset)
                }
            }

            if sPct != nil || wPct != nil {
                families.append(ModelFamilyQuota(
                    name: familyName,
                    sessionLimitPercent: sPct,
                    sessionResetText: sReset,
                    weeklyLimitPercent: wPct,
                    weeklyResetText: wReset,
                    isPercentUsed: false
                ))
            }
        }

        if families.isEmpty { return nil }

        var usage = AgentUsageData(agent: .antigravity, modelFamilies: families)
        usage.isLiveSource = true
        usage.sourceAuthority = "live_first_party"
        usage.quotaSource = "agy_local_retrieve_user_quota_summary"
        usage.freshness = "Fresh"
        usage.quotaTimestamp = Date()
        usage.parserDecision = "parsed_live_retrieve_user_quota_summary"
        usage.lastUpdated = Date()
        return usage
    }

    public func queryGetUserStatus(port: Int, csrfToken: String?) -> AgentUsageData? {
        guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus") else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = csrfToken, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        req.httpBody = "{\"metadata\":{\"ideName\":\"antigravity\",\"extensionName\":\"antigravity\",\"locale\":\"en\"}}".data(using: .utf8)

        let sema = DispatchSemaphore(value: 0)
        var fetchedData: Data? = nil

        session.dataTask(with: req) { data, resp, err in
            if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200, let data = data {
                fetchedData = data
            }
            sema.signal()
        }.resume()

        _ = sema.wait(timeout: .now() + 1.5)
        session.finishTasksAndInvalidate()

        guard let data = fetchedData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseAntigravityUserStatusJSON(json)
    }

    public func parseAntigravityUserStatusJSON(_ json: [String: Any]) -> AgentUsageData? {
        let userStatus = (json["userStatus"] as? [String: Any]) ?? json
        let cascadeCfg = userStatus["cascadeModelConfigData"] as? [String: Any]
        let rawConfigs = (cascadeCfg?["clientModelConfigs"] as? [[String: Any]])
            ?? ((userStatus["clientModelConfig"] as? [String: Any])?["models"] as? [[String: Any]])
            ?? []

        if rawConfigs.isEmpty { return nil }

        var geminiFractions: [Double] = []
        var geminiResets: [String] = []
        var claudeGptFractions: [Double] = []
        var claudeGptResets: [String] = []

        for m in rawConfigs {
            let label = (m["label"] as? String) ?? ""
            let modelId = (m["modelId"] as? String) ?? ""
            let qInfo = m["quotaInfo"] as? [String: Any]
            let rem = (qInfo?["remainingFraction"] as? NSNumber)?.doubleValue
            let reset = qInfo?["resetTime"] as? String

            let combined = (label + " " + modelId).lowercased()
            if combined.contains("gemini") {
                if let rem = rem {
                    geminiFractions.append(rem)
                } else if reset != nil && !reset!.isEmpty {
                    geminiFractions.append(0.0)
                }
                if let reset = reset, !reset.isEmpty {
                    geminiResets.append(reset)
                }
            } else if combined.contains("claude") || combined.contains("gpt") || combined.contains("sonnet") || combined.contains("opus") {
                if let rem = rem {
                    claudeGptFractions.append(rem)
                } else if reset != nil && !reset!.isEmpty {
                    claudeGptFractions.append(0.0)
                }
                if let reset = reset, !reset.isEmpty {
                    claudeGptResets.append(reset)
                }
            }
        }

        var families: [ModelFamilyQuota] = []

        if !geminiFractions.isEmpty || !geminiResets.isEmpty {
            let minFraction = geminiFractions.min() ?? 0.0
            let percentLeft = Double(Int(round(minFraction * 100.0)))
            let resetText = formatResetText(from: geminiResets.first)
            families.append(ModelFamilyQuota(
                name: "Gemini",
                sessionLimitPercent: percentLeft,
                sessionResetText: resetText,
                weeklyLimitPercent: nil,
                weeklyResetText: nil,
                isPercentUsed: false
            ))
        }

        if !claudeGptFractions.isEmpty || !claudeGptResets.isEmpty {
            let minFraction = claudeGptFractions.min() ?? 0.0
            let percentLeft = Double(Int(round(minFraction * 100.0)))
            let resetText = formatResetText(from: claudeGptResets.first)
            families.append(ModelFamilyQuota(
                name: "Claude/GPT",
                sessionLimitPercent: percentLeft,
                sessionResetText: resetText,
                weeklyLimitPercent: nil,
                weeklyResetText: nil,
                isPercentUsed: false
            ))
        }

        var usage = AgentUsageData(agent: .antigravity, modelFamilies: families)
        usage.isLiveSource = true
        usage.sourceAuthority = "live_first_party"
        usage.quotaSource = "agy_local_get_user_status"
        usage.freshness = "Fresh"
        usage.quotaTimestamp = Date()
        usage.parserDecision = "parsed_live_get_user_status"
        usage.lastUpdated = Date()
        return usage
    }

    public static func formatResetDateTime(date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let calendar = Calendar.current
        let diff = date.timeIntervalSince(now)

        if diff <= 0 {
            return "soon"
        }

        let relString: String
        if diff < 3600 {
            let mins = max(1, Int(round(diff / 60.0)))
            relString = "in \(mins)m"
        } else if diff < 86400 {
            let hours = Int(diff / 3600.0)
            let mins = (Int(diff) / 60) % 60
            if mins > 0 {
                relString = "in \(hours)h \(String(format: "%02dm", mins))"
            } else {
                relString = "in \(hours)h"
            }
        } else {
            let days = Int(diff / 86400.0)
            let hours = Int((diff.truncatingRemainder(dividingBy: 86400.0)) / 3600.0)
            if hours > 0 {
                relString = "in \(days)d \(hours)h"
            } else {
                relString = "in \(days)d"
            }
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return "today \(timeStr) (\(relString))"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = "MMM d"
            let dateStr = dateFormatter.string(from: date)
            return "\(dateStr) \(timeStr) (\(relString))"
        }
    }

    public func formatResetText(from isoString: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let isoString = isoString, !isoString.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoString)
        }
        guard let targetDate = date else { return isoString }
        return "resets \(AntigravityLocalQuotaConnector.formatResetDateTime(date: targetDate, now: now, timeZone: timeZone))"
    }
}

// MARK: - Codex App-Server JSON-RPC Quota Connector
public final class CodexAppServerQuotaConnector: @unchecked Sendable {
    public static let shared = CodexAppServerQuotaConnector()

    private init() {}

    public func findCodexBinary() -> String? {
        let candidates = [
            "/Users/ava/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["codex"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func fetchQuota() -> AgentUsageData? {
        guard let codexPath = findCodexBinary() else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: codexPath)
        task.arguments = ["app-server", "--stdio"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            return nil
        }

        let initReq = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"AgentSignalBar\",\"version\":\"1.0\"}}}\n"
        let notifReq = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}\n"
        let rateReq = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n"

        if let d1 = initReq.data(using: .utf8) { inPipe.fileHandleForWriting.write(d1) }
        if let dN = notifReq.data(using: .utf8) { inPipe.fileHandleForWriting.write(dN) }
        if let d2 = rateReq.data(using: .utf8) { inPipe.fileHandleForWriting.write(d2) }

        let sema = DispatchSemaphore(value: 0)
        var receivedOutput = ""
        let outHandle = outPipe.fileHandleForReading

        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            if let str = String(data: chunk, encoding: .utf8) {
                receivedOutput += str
                if receivedOutput.contains("\"id\":2") || receivedOutput.contains("\"id\": 2") {
                    outHandle.readabilityHandler = nil
                    sema.signal()
                }
            }
        }

        if sema.wait(timeout: .now() + 2.0) == .timedOut {
            outHandle.readabilityHandler = nil
            task.terminate()
            task.waitUntilExit()
        } else {
            outHandle.readabilityHandler = nil
            task.terminate()
            task.waitUntilExit()
        }

        return parseCodexAppServerOutput(receivedOutput)
    }

    public func parseCodexAppServerOutput(_ output: String) -> AgentUsageData? {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int, id == 2,
                  let result = json["result"] as? [String: Any] else {
                continue
            }

            return parseCodexRateLimitsResult(result)
        }
        return nil
    }

    public func parseCodexRateLimitsResult(_ result: [String: Any]) -> AgentUsageData? {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else { return nil }

        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        let creditsSummary = result["rateLimitResetCredits"] as? [String: Any]
        let availableResetCredits = creditsSummary?["availableCount"] as? Int

        let rateLimitReachedType = rateLimits["rateLimitReachedType"] as? String
        var isExhausted = rateLimitReachedType != nil

        var weeklyPercent: Double? = nil
        var sessionPercent: Double? = nil
        var weeklyResetText: String? = nil
        var sessionResetText: String? = nil

        func processWindow(_ win: [String: Any]?) {
            guard let win = win else { return }
            let used = (win["usedPercent"] as? NSNumber)?.doubleValue ?? 0.0
            let durationMins = (win["windowDurationMins"] as? NSNumber)?.int64Value ?? 0
            let resetsAt = (win["resetsAt"] as? NSNumber)?.int64Value

            if used >= 100.0 {
                isExhausted = true
            }

            if durationMins >= 1440 { // Daily or Weekly
                weeklyPercent = used
                if let resetsAt = resetsAt {
                    weeklyResetText = formatCodexResetText(resetsAt: resetsAt)
                }
            } else { // 5-Hour or shorter
                sessionPercent = used
                if let resetsAt = resetsAt {
                    sessionResetText = formatCodexResetText(resetsAt: resetsAt)
                }
            }
        }

        processWindow(primary)
        processWindow(secondary)

        var usage = AgentUsageData(agent: .codex)
        usage.weeklyLimitPercent = isExhausted ? max(weeklyPercent ?? 100.0, 100.0) : weeklyPercent
        usage.weeklyResetText = weeklyResetText
        usage.sessionLimitPercent = sessionPercent
        usage.sessionResetText = sessionResetText
        usage.resetCardCount = availableResetCredits
        usage.isPercentUsed = true
        usage.isLiveSource = true
        usage.sourceAuthority = "live_first_party"
        usage.quotaSource = "codex_app_server"
        usage.freshness = "Fresh"
        usage.quotaTimestamp = Date()
        usage.parserDecision = "parsed_live_codex_app_server"
        usage.lastUpdated = Date()
        return usage
    }

    public func formatCodexResetText(resetsAt: Int64, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        return "resets \(AntigravityLocalQuotaConnector.formatResetDateTime(date: date, now: now, timeZone: timeZone))"
    }
}
