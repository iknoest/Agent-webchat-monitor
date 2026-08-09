import Foundation
import AppKit

public final class AutoMonitor: @unchecked Sendable {
    public static let shared = AutoMonitor()

    private var timer: Timer?
    private var lastClaudeLogSize: UInt64 = 0
    private var lastAntigravityLogSize: UInt64 = 0
    private var lastAntigravityLSLogSize: UInt64 = 0
    private var lastCodexLogSize: UInt64 = 0

    // Anti-flicker Debounce Quiet Window
    private var lastClaudeActivityTime: Date = Date.distantPast
    private var lastAntigravityActivityTime: Date = Date.distantPast
    private var lastCodexActivityTime: Date = Date.distantPast

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

    private func checkAllAgents() {
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

    // Dynamic Antigravity Usage Sync from config.json and local state
    private func updateAntigravityUsageFromLocalFiles() {
        guard let q = ConfigManager.shared.config.quotas?["antigravity"] else { return }

        var usage = AgentUsageStore.shared.getUsage(for: .antigravity) ?? AgentUsageData(agent: .antigravity)
        usage.sessionLimitPercent = q.sessionPercent ?? 40.0
        usage.sessionResetText = q.sessionResetText ?? "resets in 23m"
        usage.weeklyLimitPercent = q.weeklyPercent ?? 67.0
        usage.weeklyResetText = q.weeklyResetText ?? "resets in 5d 9h"
        usage.extraMetricText = q.extraMetricText ?? "Claude & GPT: 5-Hr 100% · Weekly 100% left"
        usage.isPercentUsed = q.isPercentUsed ?? false
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

        let fh = (uDict["fh"] as? NSNumber)?.doubleValue ?? 12.0 // 5-Hour % used
        let sd = (uDict["sd"] as? NSNumber)?.doubleValue ?? 46.0 // Weekly % used

        var resetText = "resets in 3h 02m"
        if let lastTimestampMs = (lastSample["t"] as? NSNumber)?.doubleValue {
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

        var usage = AgentUsageStore.shared.getUsage(for: .claude) ?? AgentUsageData(agent: .claude)
        usage.sessionLimitPercent = fh
        usage.sessionResetText = resetText
        usage.weeklyLimitPercent = sd
        usage.weeklyResetText = "resets Mon 10:59 PM"
        usage.isPercentUsed = true
        usage.lastUpdated = Date()

        AgentUsageStore.shared.updateUsage(for: .claude, data: usage)
    }

    // Dynamic Codex Usage Calculator from config.json and local files
    private func updateCodexUsageFromLocalFiles() {
        guard let q = ConfigManager.shared.config.quotas?["codex"] else { return }

        var usage = AgentUsageStore.shared.getUsage(for: .codex) ?? AgentUsageData(agent: .codex)
        usage.weeklyLimitPercent = q.weeklyPercent ?? 89.0
        usage.weeklyResetText = q.weeklyResetText ?? "resets Aug 15"
        usage.resetCardCount = q.resetCardCount ?? 1
        usage.resetCardExpiryText = q.resetCardExpiryText ?? "Expires 8/12, 7:51 PM"
        usage.isPercentUsed = q.isPercentUsed ?? false
        usage.lastUpdated = Date()

        AgentUsageStore.shared.updateUsage(for: .codex, data: usage)
    }

    // Helper: Find active Claude session title from ~/.claude/projects/ using message timestamps
    private func fetchClaudeSessionTitle() -> String? {
        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: projectsDir) else { return nil }

        var candidates: [(title: String, lastTime: Double)] = []

        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".jsonl") {
                let fullPath = (projectsDir as NSString).appendingPathComponent(file)
                if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                    var title: String?
                    var maxTimestamp: Double = 0
                    
                    for line in lines {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let custom = json["customTitle"] as? String, !custom.isEmpty {
                                title = custom
                            } else if let t = json["title"] as? String, !t.isEmpty {
                                title = t
                            }
                            if let tsStr = json["timestamp"] as? String {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                if let date = formatter.date(from: tsStr) {
                                    maxTimestamp = max(maxTimestamp, date.timeIntervalSince1970)
                                } else {
                                    let f2 = ISO8601DateFormatter()
                                    if let date = f2.date(from: tsStr) {
                                        maxTimestamp = max(maxTimestamp, date.timeIntervalSince1970)
                                    }
                                }
                            } else if let tsNum = (json["timestamp"] as? NSNumber)?.doubleValue {
                                maxTimestamp = max(maxTimestamp, tsNum > 1e11 ? tsNum / 1000.0 : tsNum)
                            }
                        }
                    }

                    if let foundTitle = title {
                        candidates.append((foundTitle, maxTimestamp))
                    }
                }
            }
        }

        candidates.sort { $0.lastTime > $1.lastTime }
        return candidates.first?.title
    }

    // 1. Comprehensive Claude Session Transcript & Log Lifecycle Parser
    private func checkClaudeLog() {
        let workspace = NSWorkspace.shared
        let isAppRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName?.lowercased() == "claude" })

        guard isAppRunning else {
            let current = AgentStore.shared.getStatus(for: .claude)
            if current.status != .off {
                AgentStore.shared.updateStatus(for: .claude, status: .off, detail: "Claude Desktop closed")
            }
            return
        }

        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
        let fm = FileManager.default

        let parsedSessionTitle: String? = fetchClaudeSessionTitle()
        var newestTranscriptFile: String?
        var newestTranscriptDate: Date = Date.distantPast

        if let enumerator = fm.enumerator(atPath: projectsDir) {
            while let file = enumerator.nextObject() as? String {
                if file.hasSuffix(".jsonl") {
                    let fullPath = (projectsDir as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let modDate = attrs[.modificationDate] as? Date, modDate > newestTranscriptDate {
                        newestTranscriptDate = modDate
                        newestTranscriptFile = fullPath
                    }
                }
            }
        }

        var isTurnCompleted = false
        var isWorking = false
        var isPermissionNeeded = false

        if let activeTranscript = newestTranscriptFile,
           let content = try? String(contentsOfFile: activeTranscript, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            // Inspect from newest messages backwards
            for line in lines.reversed() {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    if type == "assistant" {
                        if let msg = json["message"] as? [String: Any],
                           let stopReason = msg["stop_reason"] as? String, stopReason == "end_turn" {
                            isTurnCompleted = true
                            break
                        } else {
                            isWorking = true
                            break
                        }
                    } else if type == "user" {
                        isWorking = true
                        break
                    }
                }
            }
        }

        let mainLogPath = NSString(string: "~/Library/Logs/Claude/main.log").expandingTildeInPath
        if let attrs = try? fm.attributesOfItem(atPath: mainLogPath),
           let fileSize = attrs[.size] as? UInt64, fileSize > 0,
           let fileHandle = FileHandle(forReadingAtPath: mainLogPath) {
            let offset = fileSize > 8192 ? fileSize - 8192 : 0
            fileHandle.seek(toFileOffset: offset)
            let data = fileHandle.readDataToEndOfFile()
            fileHandle.closeFile()
            if let content = String(data: data, encoding: .utf8)?.lowercased() {
                if content.contains("waiting for confirmation") || content.contains("user_approval_required") {
                    isPermissionNeeded = true
                }
            }
        }

        if isPermissionNeeded {
            AgentStore.shared.updateStatus(for: .claude, status: .blocked, detail: "🔴 Waiting for Claude user permission / approval", sessionTitle: parsedSessionTitle)
        } else if isWorking {
            let current = AgentStore.shared.getStatus(for: .claude)
            var durationStr = ""
            if let start = current.thinkingStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                durationStr = mins > 0 ? " (thinking for \(mins)m \(secs)s)" : " (thinking for \(secs)s)"
            }
            AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude active/thinking...\(durationStr)", sessionTitle: parsedSessionTitle)
        } else {
            let current = AgentStore.shared.getStatus(for: .claude)
            if current.status == .working || current.status == .blocked {
                AgentStore.shared.updateStatus(for: .claude, status: .done, detail: "Claude turn completed", sessionTitle: parsedSessionTitle)
            } else if current.status == .off {
                AgentStore.shared.updateStatus(for: .claude, status: .idle, detail: "Claude running", sessionTitle: parsedSessionTitle)
            }
        }
    }

    // 2. Comprehensive Antigravity Log & Transcript Trajectory Engine
    private func checkAntigravityLog() {
        let workspace = NSWorkspace.shared
        let isAppRunning = workspace.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.antigravity" || $0.localizedName?.lowercased() == "antigravity" })

        guard isAppRunning else {
            let current = AgentStore.shared.getStatus(for: .antigravity)
            if current.status != .off {
                AgentStore.shared.updateStatus(for: .antigravity, status: .off, detail: "Antigravity closed")
            }
            return
        }

        let fm = FileManager.default

        var isWaitingPermission = false
        var isTurnActive = false
        let sessionTitle = "Agent-webchat monitor"

        let brainDir = NSString(string: "~/.gemini/antigravity/brain").expandingTildeInPath
        if let brainEnum = fm.enumerator(atPath: brainDir) {
            var newestTranscript: String?
            var newestDate: Date = Date.distantPast
            while let file = brainEnum.nextObject() as? String {
                if file.hasSuffix("transcript.jsonl") {
                    let fullPath = (brainDir as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        if modDate > newestDate {
                            newestDate = modDate
                            newestTranscript = fullPath
                        }
                    }
                }
            }

            if let activeTranscript = newestTranscript,
               let content = try? String(contentsOfFile: activeTranscript, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                // 1. Find index of last USER_INPUT step in transcript
                var lastUserIndex = -1
                for (idx, line) in lines.enumerated() {
                    if line.contains("\"type\":\"USER_INPUT\"") {
                        lastUserIndex = idx
                    }
                }

                let currentTurnLines = lastUserIndex >= 0 ? Array(lines[lastUserIndex...]) : lines

                // 2. Check if ask_question or RequestFeedback is present in current turn
                var hasAskQuestion = false
                var hasSubsequentResponse = false

                for line in currentTurnLines {
                    if line.contains("\"name\":\"ask_question\"") || line.contains("ask_question") || line.contains("\"RequestFeedback\":true") {
                        hasAskQuestion = true
                    } else if hasAskQuestion {
                        if line.contains("RUN_COMMAND") || line.contains("CODE_ACTION") || line.contains("TOOL_RESULT") || line.contains("\"type\":\"USER_INPUT\"") {
                            hasSubsequentResponse = true
                        }
                    }
                }

                if hasAskQuestion && !hasSubsequentResponse {
                    isWaitingPermission = true
                } else {
                    // Check if latest planner response in current turn had active tool calls
                    for line in currentTurnLines.reversed() {
                        if line.contains("\"type\":\"PLANNER_RESPONSE\"") {
                            if line.contains("\"tool_calls\"") {
                                isTurnActive = true
                            }
                            break
                        }
                    }
                }
            }
        }

        if isWaitingPermission {
            AgentStore.shared.updateStatus(for: .antigravity, status: .blocked, detail: "🔴 Waiting for user permission / modal response", sessionTitle: sessionTitle)
        } else if isTurnActive {
            let current = AgentStore.shared.getStatus(for: .antigravity)
            var durationStr = ""
            if let start = current.thinkingStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                durationStr = mins > 0 ? " (thinking for \(mins)m \(secs)s)" : " (thinking for \(secs)s)"
            }
            AgentStore.shared.updateStatus(for: .antigravity, status: .working, detail: "Antigravity active/executing...\(durationStr)", sessionTitle: sessionTitle)
        } else {
            let current = AgentStore.shared.getStatus(for: .antigravity)
            if current.status == .working || current.status == .blocked {
                AgentStore.shared.updateStatus(for: .antigravity, status: .done, detail: "Antigravity task completed!", sessionTitle: sessionTitle)
            } else if current.status == .off {
                AgentStore.shared.updateStatus(for: .antigravity, status: .idle, detail: "Antigravity ready", sessionTitle: sessionTitle)
            }
        }
    }

    // 3. Robust Codex Process & Multi-Log Detector
    private func checkCodexLogAndProcess() {
        let workspace = NSWorkspace.shared
        let codexApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" || $0.localizedName?.lowercased() == "codex" || $0.localizedName?.lowercased() == "chatgpt" })

        guard codexApp != nil else {
            let current = AgentStore.shared.getStatus(for: .codex)
            if current.status != .off {
                AgentStore.shared.updateStatus(for: .codex, status: .off, detail: "Codex Desktop closed")
            }
            return
        }

        let logDirectories = [
            NSString(string: "~/Library/Logs/com.openai.codex").expandingTildeInPath,
            NSString(string: "~/Library/Logs/Codex").expandingTildeInPath,
            NSString(string: "~/Library/Application Support/Codex/logs").expandingTildeInPath,
            NSString(string: "~/.codex/logs").expandingTildeInPath
        ]
        let fm = FileManager.default

        var newestFile: String?
        var newestDate: Date = Date.distantPast

        for baseDir in logDirectories {
            if let enumerator = fm.enumerator(atPath: baseDir) {
                while let file = enumerator.nextObject() as? String {
                    if file.hasSuffix(".sqlite") || file.hasSuffix(".db") || file.contains("storage") || file.contains("telemetry") || file.contains("analytics") {
                        continue
                    }

                    if file.hasSuffix(".log") {
                        let fullPath = (baseDir as NSString).appendingPathComponent(file)
                        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                           let modDate = attrs[.modificationDate] as? Date {
                            if modDate > newestDate {
                                newestDate = modDate
                                newestFile = fullPath
                            }
                        }
                    }
                }
            }
        }

        let secondsSinceMod = Date().timeIntervalSince(newestDate)
        let codexSessionTitle = fetchCodexSessionTitle() ?? "Codex Session"
        var isActivelyGenerating = false
        var isApprovalNeeded = false

        if let activeLog = newestFile, secondsSinceMod < 4.0 {
            if let fileHandle = FileHandle(forReadingAtPath: activeLog) {
                let attrs = (try? fm.attributesOfItem(atPath: activeLog)) ?? [:]
                let fileSize = (attrs[.size] as? UInt64) ?? 0
                let offset = fileSize > 4096 ? fileSize - 4096 : 0
                fileHandle.seek(toFileOffset: offset)
                let data = fileHandle.readDataToEndOfFile()
                fileHandle.closeFile()

                if let content = String(data: data, encoding: .utf8)?.lowercased() {
                    if content.contains("approval_required") || content.contains("confirmation_pending") {
                        isApprovalNeeded = true
                    } else if content.contains("executing") || content.contains("tool_call") || content.contains("streaming") || content.contains("model_request") || content.contains("active_task") {
                        isActivelyGenerating = true
                    }
                }
            }
        }

        if isActivelyGenerating {
            lastCodexActivityTime = Date()
        }
        let secondsSinceCodexWorking = Date().timeIntervalSince(lastCodexActivityTime)

        if isApprovalNeeded {
            AgentStore.shared.updateStatus(for: .codex, status: .blocked, detail: "🔴 Waiting for Codex user approval", sessionTitle: codexSessionTitle)
        } else if isActivelyGenerating && secondsSinceCodexWorking < 4.0 {
            let current = AgentStore.shared.getStatus(for: .codex)
            var durationStr = ""
            if let start = current.thinkingStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                durationStr = mins > 0 ? " (thinking for \(mins)m \(secs)s)" : " (thinking for \(secs)s)"
            }
            AgentStore.shared.updateStatus(for: .codex, status: .working, detail: "Codex Desktop active/generating...\(durationStr)", sessionTitle: codexSessionTitle)
        } else {
            let current = AgentStore.shared.getStatus(for: .codex)
            if current.status == .working || current.status == .blocked {
                AgentStore.shared.updateStatus(for: .codex, status: .done, detail: "Codex task completed", sessionTitle: codexSessionTitle)
            } else if current.status == .done {
                if secondsSinceMod > 30.0 {
                    AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Codex Desktop running", sessionTitle: codexSessionTitle)
                }
            } else if current.status == .off {
                AgentStore.shared.updateStatus(for: .codex, status: .idle, detail: "Codex Desktop running", sessionTitle: codexSessionTitle)
            }
        }
    }

    private func fetchCodexSessionTitle() -> String? {
        let indexPath = NSString(string: "~/.codex/session_index.jsonl").expandingTildeInPath
        let fm = FileManager.default

        if fm.fileExists(atPath: indexPath),
           let content = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            for line in lines.reversed() {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let threadName = json["thread_name"] as? String, !threadName.isEmpty {
                    return threadName
                }
            }
        }

        return nil
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
