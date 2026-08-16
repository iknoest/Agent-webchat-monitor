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
        pollBodyHandler = nil
        checkLock.unlock()
        resetProcessTracking()
    }

    public func start() {
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

        checkClaudeLog()
        checkAntigravityLog()
        checkCodexLogAndProcess()
        checkChatGPTExpiry()

        // Real-time usage limit update from local history files
        updateClaudeUsageFromLocalHistory()
        updateCodexUsageFromLocalFiles()
        updateAntigravityUsageFromLocalFiles()
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





    // Dynamic Antigravity Usage Sync from config.json and local state (No fake hardcoded fallback percentages)
    private func updateAntigravityUsageFromLocalFiles() {
        let q = ConfigManager.shared.config.quotas?["antigravity"]

        var usage = AgentUsageStore.shared.getUsage(for: .antigravity) ?? AgentUsageData(agent: .antigravity)
        usage.sessionLimitPercent = q?.sessionPercent
        usage.sessionResetText = q?.sessionResetText
        usage.weeklyLimitPercent = q?.weeklyPercent
        usage.weeklyResetText = q?.weeklyResetText
        usage.extraMetricText = q?.extraMetricText ?? "Live disk quota unavailable"
        usage.isPercentUsed = q?.isPercentUsed ?? false
        usage.isLiveSource = false
        usage.quotaSource = "none"
        usage.quotaTimestamp = nil
        usage.parserDecision = "no_live_disk_file"
        usage.freshness = "Unavailable"
        usage.lastUpdated = Date()

        AgentUsageStore.shared.updateUsage(for: .antigravity, data: usage)
    }

    // Dynamic Claude Usage Calculator directly from plan-usage-history.json (JSONLines format)
    private func updateClaudeUsageFromLocalHistory() {
        let path = NSString(string: "~/Library/Application Support/Claude/plan-usage-history.json").expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let lastSample = samples.last,
              let uDict = lastSample["u"] as? [String: Any] else {
            return
        }

        let fh = (uDict["fh"] as? NSNumber)?.doubleValue ?? 0.0 // 5-Hour % used
        let sd = (uDict["sd"] as? NSNumber)?.doubleValue ?? 0.0 // Weekly % used

        var sampleDate: Date? = nil
        var resetText = "resets in 3h 02m"

        if let lastTimestampMs = (lastSample["t"] as? NSNumber)?.doubleValue {
            sampleDate = Date(timeIntervalSince1970: lastTimestampMs / 1000.0)
            let windowDurationMs: Double = 5.0 * 3600.0 * 1000.0
            let nowMs = Date().timeIntervalSince1970 * 1000.0
            
            var windowStartMs = lastTimestampMs
            for sample in samples.reversed() {
                if let u = sample["u"] as? [String: Any],
                   let fhVal = (u["fh"] as? NSNumber)?.doubleValue, fhVal == 0 {
                    if let t = (sample["t"] as? NSNumber)?.doubleValue {
                        windowStartMs = t
                        break
                    }
                }
            }

            let resetTimeMs = windowStartMs + windowDurationMs
            if resetTimeMs > nowMs {
                let diffSecs = Int((resetTimeMs - nowMs) / 1000.0)
                let hrs = diffSecs / 3600
                let mins = (diffSecs % 3600) / 60
                resetText = "resets in \(hrs)h \(mins)m"
            }
        }

        let isStale = sampleDate != nil && Date().timeIntervalSince(sampleDate!) > 86400

        var usage = AgentUsageStore.shared.getUsage(for: .claude) ?? AgentUsageData(agent: .claude)
        usage.sessionLimitPercent = fh
        usage.sessionResetText = resetText
        usage.weeklyLimitPercent = sd
        usage.weeklyResetText = "resets Mon 10:59 PM"
        usage.isPercentUsed = true
        usage.isLiveSource = true
        usage.quotaSource = "plan-usage-history.json"
        usage.quotaTimestamp = sampleDate
        usage.parserDecision = isStale ? "stale_sample_history" : "parsed_live_sample"
        usage.freshness = isStale ? "Stale" : "Fresh"
        usage.lastUpdated = Date()

        AgentUsageStore.shared.updateUsage(for: .claude, data: usage)
    }

    // Dynamic Codex Usage Calculator from config.json and local files (No fake hardcoded fallback percentages)
    private func updateCodexUsageFromLocalFiles() {
        let q = ConfigManager.shared.config.quotas?["codex"]

        var usage = AgentUsageStore.shared.getUsage(for: .codex) ?? AgentUsageData(agent: .codex)
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
        usage.lastUpdated = Date()

        AgentUsageStore.shared.updateUsage(for: .codex, data: usage)
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
        let isAppRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName?.lowercased() == "claude" })

        guard isAppRunning else {
            AgentStore.shared.updateStatus(for: .claude, status: .off, detail: "Claude Code closed")
            AgentStore.shared.syncSessions(for: .claude, activeSessions: [], processRunning: false)
            return
        }

        AgentStore.shared.pruneStaleClaudeSessions()

        let currentClaudeSessions = AgentStore.shared.getSessions(for: .claude)
        if currentClaudeSessions.isEmpty {
            AgentStore.shared.updateStatus(for: .claude, status: .idle, detail: "Monitoring via Claude Native Hooks (Ready)")
            AgentStore.shared.syncSessions(for: .claude, activeSessions: [], processRunning: true)
        }
    }

    // 2. Antigravity Process Watcher (Provider-Native Lifecycle Hooks)
    private func checkAntigravityLog() {
        let workspace = NSWorkspace.shared
        let isAppRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.antigravity" || $0.localizedName?.lowercased() == "antigravity" })

        guard isAppRunning else {
            AgentStore.shared.updateStatus(for: .antigravity, status: .off, detail: "Antigravity closed")
            AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [], processRunning: false)
            return
        }

        checkAntigravityNotificationCenterBanner()

        let currentAntigravitySessions = AgentStore.shared.getSessions(for: .antigravity)
        if currentAntigravitySessions.isEmpty {
            AgentStore.shared.updateStatus(for: .antigravity, status: .idle, detail: "Monitoring via Antigravity Native Hooks (Ready)")
            AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
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
        public let updatedAtMs: Int64

        public init(id: String, title: String, rolloutPath: String, updatedAtMs: Int64) {
            self.id = id
            self.title = title
            self.rolloutPath = rolloutPath
            self.updatedAtMs = updatedAtMs
        }
    }

    public func fetchCodexThreads(limit: Int = 5) -> [CodexThreadInfo] {
        let fm = FileManager.default
        let dbPath = NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
        let globalStatePath = NSString(string: "~/.codex/.codex-global-state.json").expandingTildeInPath

        var targetThreadId: String? = nil

        if fm.fileExists(atPath: globalStatePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: globalStatePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let selProj = json["selected-project"] as? [String: Any],
           let projId = selProj["projectId"] as? String,
           let orders = json["sidebar-project-thread-orders"] as? [String: Any],
           let projOrder = orders[projId] as? [String: Any],
           let threadIds = projOrder["threadIds"] as? [String],
           let topId = threadIds.first, !topId.isEmpty {
            targetThreadId = topId
        }

        if targetThreadId == nil {
            let locksDir = NSString(string: "~/.codex/thread-writer-locks").expandingTildeInPath
            if let lockFiles = try? fm.contentsOfDirectory(atPath: locksDir) {
                let activeLocks = lockFiles.filter { $0.hasSuffix(".lock") && !$0.hasPrefix(".") && $0 != ".coordination.lock" }
                if let newestLock = activeLocks.first {
                    targetThreadId = newestLock.replacingOccurrences(of: ".lock", with: "")
                }
            }
        }

        var results: [CodexThreadInfo] = []
        var seenIds = Set<String>()

        if fm.fileExists(atPath: dbPath) {
            if let tid = targetThreadId {
                let query = "SELECT id || '|||' || title || '|||' || rollout_path || '|||' || updated_at_ms FROM threads WHERE id='\(tid)';"
                if let output = runProcessWithTimeout(
                    executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                    arguments: [dbPath, query],
                    timeoutSeconds: 1.0
                ) {
                    let parts = output.components(separatedBy: "|||")
                    if parts.count >= 4 {
                        let tidStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        let updated = Int64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                        if !tidStr.isEmpty && !path.isEmpty && fm.fileExists(atPath: path) {
                            seenIds.insert(tidStr)
                            results.append(CodexThreadInfo(id: tidStr, title: title.isEmpty ? "Codex Session" : title, rolloutPath: path, updatedAtMs: updated))
                        }
                    }
                }
            }

            let query = "SELECT id || '|||' || title || '|||' || rollout_path || '|||' || updated_at_ms FROM threads WHERE archived=0 ORDER BY updated_at_ms DESC LIMIT \(limit);"
            if let output = runProcessWithTimeout(
                executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
                arguments: [dbPath, query],
                timeoutSeconds: 1.0
            ) {
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    let parts = line.components(separatedBy: "|||")
                    if parts.count >= 4 {
                        let tid = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        let updated = Int64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                        if !tid.isEmpty && !path.isEmpty && fm.fileExists(atPath: path) && !seenIds.contains(tid) {
                            seenIds.insert(tid)
                            results.append(CodexThreadInfo(id: tid, title: title.isEmpty ? "Codex Session" : title, rolloutPath: path, updatedAtMs: updated))
                        }
                    }
                }
            }
        }

        if results.isEmpty {
            let sessionsDir = NSString(string: "~/.codex/sessions").expandingTildeInPath
            if let enumerator = fm.enumerator(atPath: sessionsDir) {
                var newestFile: String?
                var newestDate: Date = Date.distantPast

                while let file = enumerator.nextObject() as? String {
                    if file.hasSuffix(".jsonl") {
                        let fullPath = (sessionsDir as NSString).appendingPathComponent(file)
                        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                           let modDate = attrs[.modificationDate] as? Date {
                            if modDate > newestDate {
                                newestDate = modDate
                                newestFile = fullPath
                            }
                        }
                    }
                }

                if let activeFile = newestFile {
                    let filename = (activeFile as NSString).lastPathComponent
                    results.append(CodexThreadInfo(id: filename, title: "Codex Session", rolloutPath: activeFile, updatedAtMs: Int64(newestDate.timeIntervalSince1970 * 1000.0)))
                }
            }
        }

        return Array(results.prefix(limit))
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

    // Helper: Bounded Backward-Chunk Turn Reader for Large Codex Rollouts (>128 KB)
    public func readTurnFromRollout(atPath path: String, maxBytesToScan: UInt64 = 2097152) -> (turnLines: [String], turnId: String?)? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64, fileSize > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.closeFile() }

        readTailCallCount += 1

        let bytesToRead = min(fileSize, maxBytesToScan)
        let startOffset = fileSize - bytesToRead

        handle.seek(toFileOffset: startOffset)
        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var lastTaskStartIdx = -1
        var extractedTurnId: String? = nil

        for (idx, line) in lines.enumerated() {
            if line.contains("task_started") || line.contains("user_message") {
                lastTaskStartIdx = idx
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let payload = json["payload"] as? [String: Any] {
                        if let tid = payload["turn_id"] as? String { extractedTurnId = tid }
                        else if let id = payload["id"] as? String { extractedTurnId = id }
                    }
                }
            }
        }

        if lastTaskStartIdx >= 0 {
            let turnLines = Array(lines[lastTaskStartIdx...])
            return (turnLines, extractedTurnId ?? "\(lastTaskStartIdx)")
        } else {
            return (lines, nil)
        }
    }

    // 3. Codex Process Watcher (Session automation disabled for baseline recovery)
    private func checkCodexLogAndProcess() {
        let workspace = NSWorkspace.shared
        let codexApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" || $0.localizedName?.lowercased() == "codex" || $0.localizedName?.lowercased() == "chatgpt" })

        guard codexApp != nil else {
            AgentStore.shared.updateStatus(for: .codex, status: .off, detail: "Codex Desktop closed")
            AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: false)
            return
        }

        AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Monitoring unavailable / Experimental")
        AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    }


    private func fetchCodexSessionTitle() -> String? {
        return fetchCodexThreadInfo()?.title
    }

    // 4. ChatGPT Expiry check
    private func checkChatGPTExpiry() {
        let workspace = NSWorkspace.shared
        let isChromeRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" })

        if !isChromeRunning {
            let current = AgentStore.shared.getStatus(for: .chatgpt)
            if current.status != .off {
                AgentStore.shared.updateStatus(for: .chatgpt, status: .off, detail: "Google Chrome closed")
            }
        } else {
            let current = AgentStore.shared.getStatus(for: .chatgpt)
            if current.status == .off {
                AgentStore.shared.updateStatus(for: .chatgpt, status: .idle, detail: "Google Chrome running")
            }
        }
    }
}
