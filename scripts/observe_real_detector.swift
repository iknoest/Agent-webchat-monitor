import Foundation
import AgentSignalBarCore

let store = AgentStore.shared
let monitor = AutoMonitor.shared

func formatTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func getClaudeRealEvidence() -> (evidence: String, sessionPath: String, turnId: String, rawDecision: String) {
    guard let info = monitor.findActiveClaudeTranscriptInfo() else {
        return ("No active transcript file found", "N/A", "N/A", "idle_no_file")
    }

    let path = info.path
    let modDate = info.modDate
    let timeSinceMod = Date().timeIntervalSince(modDate)

    guard let content = monitor.readTailOfFile(atPath: path, maxBytes: 65536) else {
        return ("Unreadable transcript", path, "N/A", "error_reading")
    }

    let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    var lastHumanPromptIdx: Int? = nil
    var lastHumanPromptTimestamp: Date? = nil
    var lastHumanPromptUuid: String? = nil
    var lastAssistantStopReason: String? = nil
    var pendingToolCalls = Set<String>()
    var hasAssistantMessageInTurn = false

    for (idx, line) in lines.enumerated() {
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let type = json["type"] as? String, type == "user" {
                let origin = json["origin"] as? [String: Any]
                let isHumanOrigin = (origin?["kind"] as? String) == "human"
                let hasPromptId = json["promptId"] != nil || json["promptSource"] != nil
                let hasToolResult = json["toolUseResult"] != nil
                if isHumanOrigin || hasPromptId || !hasToolResult {
                    lastHumanPromptIdx = idx
                    if let u = json["uuid"] as? String { lastHumanPromptUuid = u }
                    else if let p = json["promptId"] as? String { lastHumanPromptUuid = p }
                    if let tsStr = json["timestamp"] as? String {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        lastHumanPromptTimestamp = formatter.date(from: tsStr) ?? ISO8601DateFormatter().date(from: tsStr)
                    }
                }
            }
        }
    }

    let turnLines = (lastHumanPromptIdx != nil && lastHumanPromptIdx! < lines.count) ? Array(lines[lastHumanPromptIdx!...]) : lines

    for line in turnLines {
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            if type == "assistant" {
                hasAssistantMessageInTurn = true
                if let msg = json["message"] as? [String: Any] {
                    if let sr = msg["stop_reason"] as? String { lastAssistantStopReason = sr }
                    if let contentArray = msg["content"] as? [[String: Any]] {
                        for item in contentArray {
                            if (item["type"] as? String) == "tool_use", let toolId = item["id"] as? String {
                                pendingToolCalls.insert(toolId)
                            }
                        }
                    }
                }
            } else if type == "user" {
                if let toolResult = json["toolUseResult"] as? [String: Any], let toolId = toolResult["tool_use_id"] as? String {
                    pendingToolCalls.remove(toolId)
                }
            }
        }
    }

    let turnUuid = lastHumanPromptUuid ?? "\(modDate.timeIntervalSince1970)"
    let turnId = "\(path)_turn_\(turnUuid)"

    let timeSincePrompt = lastHumanPromptTimestamp != nil ? Date().timeIntervalSince(lastHumanPromptTimestamp!) : timeSinceMod

    var decision = "unknown"
    if lastHumanPromptIdx != nil {
        if hasAssistantMessageInTurn && pendingToolCalls.isEmpty && lastAssistantStopReason == "end_turn" {
            decision = timeSinceMod >= 2.0 ? "isTurnCompleted (stop_reason=end_turn, mtime_\(Int(timeSinceMod))s)" : "isTurnInProgress (mtime_\(Int(timeSinceMod))s<2s)"
        } else {
            if timeSinceMod <= 300.0 || timeSincePrompt <= 300.0 {
                decision = "isTurnInProgress (mtime_\(Int(timeSinceMod))s, prompt_\(Int(timeSincePrompt))s)"
            } else {
                decision = "stale_session (mtime_\(Int(timeSinceMod))s > 300s -> idle)"
            }
        }
    } else {
        decision = timeSinceMod <= 5.0 ? "isTurnInProgress (recent_mod_\(Int(timeSinceMod))s)" : "idle"
    }

    let evidence = "JSONL lines: \(lines.count), mtime_age: \(Int(timeSinceMod))s, prompt_age: \(Int(timeSincePrompt))s, stop_reason: \(lastAssistantStopReason ?? "none")"
    return (evidence, path, turnId, decision)
}

func getCodexRealEvidence() -> (evidence: String, threadId: String, turnId: String, rawDecision: String) {
    guard let threadInfo = monitor.fetchCodexThreadInfo() else {
        return ("No active Codex thread found", "N/A", "N/A", "idle_no_thread")
    }

    let path = threadInfo.rolloutPath
    let threadModDate = Date(timeIntervalSince1970: Double(threadInfo.updatedAtMs) / 1000.0)
    let timeSinceMod = Date().timeIntervalSince(threadModDate)

    let lockPath = NSString(string: "~/.codex/thread-writer-locks/\(threadInfo.id).lock").expandingTildeInPath
    let hasActiveLock = FileManager.default.fileExists(atPath: lockPath)

    guard let content = monitor.readTailOfFile(atPath: path, maxBytes: 131072) else {
        return ("Unreadable rollout file", threadInfo.id, "N/A", "error_reading")
    }

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

    var turnId = "N/A"
    var decision = "unknown"
    var hasTerminal = false

    if lastTaskStartIdx >= 0 {
        let resolvedTurn = extractedTurnId ?? "\(lastTaskStartIdx)"
        turnId = "\(threadInfo.id)_turn_\(resolvedTurn)"
        let turnSlice = Array(lines[lastTaskStartIdx...])
        for line in turnSlice {
            if line.contains("task_complete") || line.contains("turn_aborted") {
                hasTerminal = true
                break
            }
        }
        if hasTerminal {
            decision = "isTurnCompleted (task_complete present)"
        } else if timeSinceMod <= 300.0 || hasActiveLock {
            decision = "isActivelyGenerating (mtime_\(Int(timeSinceMod))s, lock=\(hasActiveLock))"
        } else {
            decision = "stale_thread (mtime_\(Int(timeSinceMod))s > 300s -> idle)"
        }
    } else {
        decision = "no_task_start_found"
    }

    let evidence = "Thread: '\(threadInfo.title.prefix(30))...', mtime_age: \(Int(timeSinceMod))s, lock: \(hasActiveLock), has_terminal: \(hasTerminal)"
    return (evidence, threadInfo.id, turnId, decision)
}

print("time | visible/real agent activity evidence | selected session/thread ID | turnId | raw detector decision | committed status | thinkingStartTime | displayed duration")

let targetAgentStr = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "claude"
let targetAgent: AgentID = (targetAgentStr == "codex") ? .codex : .claude

var sampleCount = 0
let maxSamples = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 10) : 10

while sampleCount < maxSamples {
    sampleCount += 1

    monitor.checkAllAgents()

    let now = Date()
    let ts = formatTimestamp(now)
    let info = store.getStatus(for: targetAgent)

    let (evidence, sessionOrThread, turnId, rawDecision) = (targetAgent == .claude) ? getClaudeRealEvidence() : getCodexRealEvidence()
    let committedStatus = info.status.rawValue
    let thinkingStartStr = info.thinkingStartTime != nil ? formatTimestamp(info.thinkingStartTime!) : "nil"

    var durStr = "0s"
    if let start = info.thinkingStartTime {
        let elapsed = Int(now.timeIntervalSince(start))
        let mins = elapsed / 60
        let secs = elapsed % 60
        durStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    } else if let lastDur = info.lastDurationSeconds {
        let elapsed = Int(lastDur)
        let mins = elapsed / 60
        let secs = elapsed % 60
        durStr = mins > 0 ? "took \(mins)m \(secs)s" : "took \(secs)s"
    }

    print("\(ts) | \(evidence) | \(sessionOrThread) | \(turnId) | \(rawDecision) | \(committedStatus) | \(thinkingStartStr) | \(durStr)")

    fflush(stdout)
    if sampleCount < maxSamples {
        Thread.sleep(forTimeInterval: 2.0)
    }
}
