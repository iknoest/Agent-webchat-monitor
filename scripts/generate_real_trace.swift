import Foundation
import AgentSignalBarCore

let store = AgentStore.shared
let monitor = AutoMonitor.shared

func formatTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

print("timestamp | visible/real agent activity evidence | selected session/thread ID | turnId | raw detector decision | committed status | thinkingStartTime | displayed duration")

for i in 1...10 {
    monitor.checkAllAgents()
    let now = Date()
    let ts = formatTimestamp(now)
    
    // --- Claude Observation ---
    if let info = monitor.findActiveClaudeTranscriptInfo() {
        let path = info.path
        let modDate = info.modDate
        let timeSinceMod = Date().timeIntervalSince(modDate)
        
        var lineCount = 0
        var pendingToolCount = 0
        var stopReason = "none"
        var lastHumanPromptIdx: Int? = nil
        var lastHumanPromptUuid: String? = nil
        
        if let content = monitor.readTailOfFile(atPath: path, maxBytes: 65536) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            lineCount = lines.count
            
            for (idx, line) in lines.enumerated() {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String, type == "user" {
                    let origin = json["origin"] as? [String: Any]
                    let isHumanOrigin = (origin?["kind"] as? String) == "human"
                    let hasPromptId = json["promptId"] != nil || json["promptSource"] != nil
                    let hasToolResult = json["toolUseResult"] != nil
                    if isHumanOrigin || hasPromptId || !hasToolResult {
                        lastHumanPromptIdx = idx
                        if let u = json["uuid"] as? String { lastHumanPromptUuid = u }
                    }
                }
            }
            
            let turnLines = (lastHumanPromptIdx != nil && lastHumanPromptIdx! < lines.count) ? Array(lines[lastHumanPromptIdx!...]) : lines
            var pendingTools = Set<String>()
            
            for line in turnLines {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    if type == "assistant" {
                        if let msg = json["message"] as? [String: Any] {
                            if let sr = msg["stop_reason"] as? String { stopReason = sr }
                            if let contentArray = msg["content"] as? [[String: Any]] {
                                for item in contentArray {
                                    if (item["type"] as? String) == "tool_use", let toolId = item["id"] as? String {
                                        pendingTools.insert(toolId)
                                    }
                                }
                            }
                        }
                    } else if type == "user" {
                        if let toolResult = json["toolUseResult"] as? [String: Any], let toolId = toolResult["tool_use_id"] as? String {
                            pendingTools.remove(toolId)
                        }
                    }
                }
            }
            pendingToolCount = pendingTools.count
        }
        
        let turnUuid = lastHumanPromptUuid ?? "\(modDate.timeIntervalSince1970)"
        let turnId = "\(path)_turn_\(turnUuid)"
        
        var rawDecision = "unknown"
        if lastHumanPromptIdx != nil {
            if pendingToolCount == 0 && stopReason == "end_turn" {
                rawDecision = timeSinceMod >= 2.0 ? "isTurnCompleted" : "isTurnInProgress"
            } else {
                rawDecision = "isTurnInProgress (fallback: stop_reason=\(stopReason))"
            }
        } else {
            rawDecision = timeSinceMod <= 5.0 ? "isTurnInProgress" : "idle"
        }
        
        let cInfo = store.getStatus(for: .claude)
        let committedStatus = cInfo.status.rawValue
        let thinkingStartStr = cInfo.thinkingStartTime != nil ? formatTimestamp(cInfo.thinkingStartTime!) : "nil"
        var durStr = "0s"
        if let start = cInfo.thinkingStartTime {
            let elapsed = Int(now.timeIntervalSince(start))
            durStr = "\(elapsed)s"
        }
        
        let evidence = "[CLAUDE] last_mod: \(Int(timeSinceMod))s ago (\(Int(timeSinceMod)/3600)h ago), lines: \(lineCount), pending_tools: \(pendingToolCount), stop_reason: \(stopReason)"
        print("\(ts) | \(evidence) | \(path) | \(turnId) | \(rawDecision) | \(committedStatus) | \(thinkingStartStr) | \(durStr)")
    }
    
    // --- Codex Observation ---
    if let threadInfo = monitor.fetchCodexThreadInfo() {
        let path = threadInfo.rolloutPath
        var lineCount = 0
        var hasTerminal = false
        var lastTaskStartIdx = -1
        
        if let content = monitor.readTailOfFile(atPath: path, maxBytes: 65536) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            lineCount = lines.count
            
            for (idx, line) in lines.enumerated() {
                if line.contains("\"type\":\"task_started\"") || line.contains("\"task_started\"") || line.contains("\"type\":\"user_message\"") {
                    lastTaskStartIdx = idx
                }
            }
            if lastTaskStartIdx >= 0 {
                let turnSlice = Array(lines[lastTaskStartIdx...])
                for line in turnSlice {
                    if line.contains("\"type\":\"task_complete\"") || line.contains("\"type\":\"turn_aborted\"") || line.contains("\"task_complete\"") || line.contains("\"turn_aborted\"") {
                        hasTerminal = true
                        break
                    }
                }
            }
        }
        
        let turnId = lastTaskStartIdx >= 0 ? "\(threadInfo.id)_turn_\(lastTaskStartIdx)" : "N/A"
        let rawDecision = (lastTaskStartIdx >= 0) ? (hasTerminal ? "isTurnCompleted" : "isActivelyGenerating") : "no_task_start_found"
        
        let cxInfo = store.getStatus(for: .codex)
        let committedStatus = cxInfo.status.rawValue
        let thinkingStartStr = cxInfo.thinkingStartTime != nil ? formatTimestamp(cxInfo.thinkingStartTime!) : "nil"
        var durStr = "0s"
        if let start = cxInfo.thinkingStartTime {
            let elapsed = Int(now.timeIntervalSince(start))
            durStr = "\(elapsed)s"
        }
        
        let evidence = "[CODEX] thread: '\(threadInfo.title.prefix(30))..', lines: \(lineCount), has_terminal: \(hasTerminal)"
        print("\(ts) | \(evidence) | \(threadInfo.id) | \(turnId) | \(rawDecision) | \(committedStatus) | \(thinkingStartStr) | \(durStr)")
    }
    
    fflush(stdout)
    Thread.sleep(forTimeInterval: 1.5)
}
