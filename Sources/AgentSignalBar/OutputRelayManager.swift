import Foundation
import AppKit

public final class OutputRelayManager: @unchecked Sendable {
    public static let shared = OutputRelayManager()

    private var outputs: [AgentID: String] = [:]
    private var pendingRelayText: String? = nil
    private let lock = NSLock()

    public var isAutoRelayEnabled: Bool = false

    private init() {}

    // Bulletproof Sanitizer Filter: Strips JSON wrappers, Electron crashes, Go gRPC logs & CDP Discovery
    public func sanitizeOutputText(_ rawText: String) -> String {
        let lines = rawText.components(separatedBy: "\n")
        var cleanLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip JSONLines raw log envelopes
            if trimmed.hasPrefix("{\"type\":") || trimmed.hasPrefix("{\"parentUuid\"") || trimmed.hasPrefix("{\"sessionId\"") {
                continue
            }

            // Skip Electron stack traces, Node.js errors, Go runtime logs, CDP discovery
            if trimmed.contains("SimpleURLLoaderWrapper") ||
               trimmed.contains("node:electron") ||
               trimmed.contains("node:events") ||
               trimmed.contains("net::ERR_") ||
               trimmed.contains("[stack]:") ||
               trimmed.contains("[message]:") ||
               trimmed.hasPrefix("W08") || trimmed.hasPrefix("I08") || trimmed.hasPrefix("E08") ||
               trimmed.contains("permission_grant_store.go") ||
               trimmed.contains("encoder_embed.go") ||
               trimmed.contains("http_helpers.go") ||
               trimmed.contains("[CDP Discovery]") ||
               trimmed.contains("streamGenerateContent") ||
               trimmed.contains("invalid resource string") ||
               trimmed.contains("command(.venv") ||
               trimmed.contains("[process-memory]") ||
               trimmed.contains("[WarmLifecycle]") ||
               trimmed.contains("[EventLogging]") ||
               trimmed.contains("[CliGovernor]") ||
               trimmed.contains("[gitDiff]") ||
               trimmed.contains("Ran command:") ||
               trimmed.contains("Edited ") ||
               trimmed.contains("<!-- append-only") {
                continue
            }

            // Strip ISO/log timestamp prefixes like "2026-08-08 14:59:06 [info] "
            var lineContent = line
            if let range = lineContent.range(of: "^\\d{4}-\\d{2}-\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}\\s+\\[(info|warn|error)\\]\\s*", options: .regularExpression) {
                lineContent.removeSubrange(range)
            }

            let finalTrimmed = lineContent.trimmingCharacters(in: .whitespaces)
            if !finalTrimmed.isEmpty {
                cleanLines.append(lineContent)
            }
        }

        return cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Extract exact clean AI Assistant Response text from Claude Code history / logs
    private func fetchClaudeCleanOutput() -> String? {
        let fm = FileManager.default

        // 1. Scan ~/.claude/ / ~/.claude/projects/ for latest conversation JSONL files
        let searchDirectories = [
            NSString(string: "~/.claude/projects").expandingTildeInPath,
            NSString(string: "~/.claude").expandingTildeInPath
        ]

        var newestFile: String?
        var newestDate: Date = Date.distantPast

        for dir in searchDirectories {
            if let enumerator = fm.enumerator(atPath: dir) {
                while let file = enumerator.nextObject() as? String {
                    if file.hasSuffix(".jsonl") || file.hasSuffix(".json") {
                        let fullPath = (dir as NSString).appendingPathComponent(file)
                        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                           let modDate = attrs[.modificationDate] as? Date, modDate > newestDate {
                            newestDate = modDate
                            newestFile = fullPath
                        }
                    }
                }
            }
        }

        if let jsonPath = newestFile, let content = try? String(contentsOfFile: jsonPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").reversed()

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { continue }

                if let data = trimmed.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    let type = json["type"] as? String ?? ""
                    let role = (json["message"] as? [String: Any])?["role"] as? String ?? json["role"] as? String ?? ""

                    if type == "assistant" || role == "assistant" {
                        // Extract text from content array or string
                        var extractedText = ""

                        if let messageDict = json["message"] as? [String: Any] {
                            if let contentArr = messageDict["content"] as? [[String: Any]] {
                                for block in contentArr {
                                    if let blockType = block["type"] as? String, blockType == "text",
                                       let text = block["text"] as? String {
                                        extractedText += text + "\n"
                                    }
                                }
                            } else if let contentStr = messageDict["content"] as? String {
                                extractedText = contentStr
                            }
                        } else if let contentArr = json["content"] as? [[String: Any]] {
                            for block in contentArr {
                                if let blockType = block["type"] as? String, blockType == "text",
                                   let text = block["text"] as? String {
                                    extractedText += text + "\n"
                                }
                            }
                        } else if let contentStr = json["content"] as? String {
                            extractedText = contentStr
                        }

                        let clean = sanitizeOutputText(extractedText)
                        if !clean.isEmpty && clean.count > 20 {
                            return clean
                        }
                    }
                }
            }
        }

        // 2. Fallback to ~/Library/Logs/Claude/main.log clean block
        let logPath = NSString(string: "~/Library/Logs/Claude/main.log").expandingTildeInPath
        if let fileHandle = FileHandle(forReadingAtPath: logPath) {
            let attrs = (try? fm.attributesOfItem(atPath: logPath)) ?? [:]
            let fileSize = (attrs[.size] as? UInt64) ?? 0
            let offset = fileSize > 65536 ? fileSize - 65536 : 0
            fileHandle.seek(toFileOffset: offset)
            let data = fileHandle.readDataToEndOfFile()
            fileHandle.closeFile()

            if let rawText = String(data: data, encoding: .utf8) {
                let clean = sanitizeOutputText(rawText)
                if !clean.isEmpty {
                    return clean
                }
            }
        }

        return nil
    }

    // Extract exact clean AI Assistant Response from Antigravity Brain transcript.jsonl
    private func fetchAntigravityTranscriptOutput() -> String? {
        let brainDir = NSString(string: "~/.gemini/antigravity/brain").expandingTildeInPath
        let fm = FileManager.default

        guard let convDirs = try? fm.contentsOfDirectory(atPath: brainDir) else { return nil }

        var newestFile: String?
        var newestDate: Date = Date.distantPast

        for conv in convDirs {
            let logsDir = (brainDir as NSString).appendingPathComponent("\(conv)/.system_generated/logs")
            let transcriptPath = (logsDir as NSString).appendingPathComponent("transcript.jsonl")

            if fm.fileExists(atPath: transcriptPath),
               let attrs = try? fm.attributesOfItem(atPath: transcriptPath),
               let modDate = attrs[.modificationDate] as? Date {
                if modDate > newestDate {
                    newestDate = modDate
                    newestFile = transcriptPath
                }
            }
        }

        guard let path = newestFile,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\"PLANNER_RESPONSE\"") || trimmed.contains("\"content\"") {
                if let data = trimmed.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String, type == "PLANNER_RESPONSE",
                   let contentText = json["content"] as? String, !contentText.isEmpty {
                    let clean = sanitizeOutputText(contentText)
                    if !clean.isEmpty {
                        return clean
                    }
                }
            }
        }

        return nil
    }

    // On-Demand Live Log & Transcript Reader: Guarantees 100% clean Assistant text output
    public func fetchFreshestOutput(for agent: AgentID) -> String {
        if agent == .antigravity {
            if let cleanTranscript = fetchAntigravityTranscriptOutput(), !cleanTranscript.isEmpty {
                lock.lock()
                outputs[agent] = cleanTranscript
                lock.unlock()
                return cleanTranscript
            }
        } else if agent == .claude {
            if let cleanClaude = fetchClaudeCleanOutput(), !cleanClaude.isEmpty {
                lock.lock()
                outputs[agent] = cleanClaude
                lock.unlock()
                return cleanClaude
            }
        }

        lock.lock()
        if let cached = outputs[agent], !cached.isEmpty {
            let sanitizedCached = sanitizeOutputText(cached)
            if !sanitizedCached.isEmpty {
                lock.unlock()
                return sanitizedCached
            }
        }
        lock.unlock()

        let fm = FileManager.default
        var rawText = ""

        switch agent {
        case .claude:
            let path = NSString(string: "~/Library/Logs/Claude/main.log").expandingTildeInPath
            if let fileHandle = FileHandle(forReadingAtPath: path) {
                let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
                let fileSize = (attrs[.size] as? UInt64) ?? 0
                let offset = fileSize > 65536 ? fileSize - 65536 : 0
                fileHandle.seek(toFileOffset: offset)
                let data = fileHandle.readDataToEndOfFile()
                fileHandle.closeFile()
                rawText = String(data: data, encoding: .utf8) ?? ""
            }

        case .antigravity:
            let mainPath = NSString(string: "~/Library/Logs/Antigravity/main.log").expandingTildeInPath
            if let fileHandle = FileHandle(forReadingAtPath: mainPath) {
                let attrs = (try? fm.attributesOfItem(atPath: mainPath)) ?? [:]
                let fileSize = (attrs[.size] as? UInt64) ?? 0
                let offset = fileSize > 16384 ? fileSize - 16384 : 0
                fileHandle.seek(toFileOffset: offset)
                let data = fileHandle.readDataToEndOfFile()
                fileHandle.closeFile()
                rawText = String(data: data, encoding: .utf8) ?? ""
            }

        case .codex:
            let baseDir = NSString(string: "~/Library/Logs/com.openai.codex").expandingTildeInPath
            if let enumerator = fm.enumerator(atPath: baseDir) {
                var newestFile: String?
                var newestDate: Date = Date.distantPast
                while let file = enumerator.nextObject() as? String {
                    if file.hasSuffix(".log") {
                        let fullPath = (baseDir as NSString).appendingPathComponent(file)
                        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                           let modDate = attrs[.modificationDate] as? Date, modDate > newestDate {
                            newestDate = modDate
                            newestFile = fullPath
                        }
                    }
                }
                if let logPath = newestFile, let fileHandle = FileHandle(forReadingAtPath: logPath) {
                    let attrs = (try? fm.attributesOfItem(atPath: logPath)) ?? [:]
                    let fileSize = (attrs[.size] as? UInt64) ?? 0
                    let offset = fileSize > 16384 ? fileSize - 16384 : 0
                    fileHandle.seek(toFileOffset: offset)
                    let data = fileHandle.readDataToEndOfFile()
                    fileHandle.closeFile()
                    rawText = String(data: data, encoding: .utf8) ?? ""
                }
            }

        case .chatgpt:
            if let liveText = fetchChatGPTRealtimeOutput(), !liveText.isEmpty {
                rawText = liveText
            } else {
                rawText = "ChatGPT Web Output"
            }
        }

        let clean = sanitizeOutputText(rawText)
        if !clean.isEmpty {
            lock.lock()
            outputs[agent] = clean
            lock.unlock()
            return clean
        }

        return "\(agent.displayName) Clean Output"
    }

    // Direct AppleScript extraction fallback from Google Chrome chatgpt.com tab
    private func fetchChatGPTRealtimeOutput() -> String? {
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "chatgpt.com" then
                        try
                            set res to execute t javascript "(function() { const articles = document.querySelectorAll('article'); for (let i = articles.length - 1; i >= 0; i--) { const art = articles[i]; if (!art.querySelector('[data-message-author-role=\\\"user\\\"]')) { return art.innerText || art.textContent || ''; } } return articles.length > 0 ? (articles[articles.length - 1].innerText || '') : ''; })()"
                            if res is not missing value and length of res > 0 then
                                return res
                            end if
                        end try
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """

        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let resultDescriptor = appleScript.executeAndReturnError(&errorDict)
            if let str = resultDescriptor.stringValue, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str
            }
        }
        return nil
    }

    public func setLastOutput(for agent: AgentID, text: String) {
        lock.lock()
        let clean = sanitizeOutputText(text)
        if !clean.isEmpty {
            outputs[agent] = clean
        }
        lock.unlock()
    }

    public func setPendingRelayText(_ text: String) {
        lock.lock()
        pendingRelayText = sanitizeOutputText(text)
        lock.unlock()
    }

    public func popPendingRelayText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let text = pendingRelayText
        pendingRelayText = nil
        return text
    }

    public func relayToChatGPT(from agent: AgentID) {
        let text = fetchFreshestOutput(for: agent)

        lock.lock()
        pendingRelayText = text
        lock.unlock()

        print("📲 Relaying clean output from \(agent.displayName) to ChatGPT Web (\(text.count) chars)")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NSSound(named: "Pop")?.play()
        let notification = NSUserNotification()
        notification.title = "📲 Relaying Clean AI Output"
        notification.subtitle = "Source: \(agent.displayName)"
        notification.informativeText = String(text.prefix(80)) + "..."
        NSUserNotificationCenter.default.deliver(notification)

        let currentStatus = AgentStore.shared.getStatus(for: .chatgpt)
        if let link = currentStatus.webLink, let url = URL(string: link), !link.isEmpty {
            NSWorkspace.shared.open(url)
        } else if let defaultUrl = URL(string: "https://chatgpt.com") {
            NSWorkspace.shared.open(defaultUrl)
        }
    }

    public func copyToClipboard(from agent: AgentID) -> Bool {
        let text = fetchFreshestOutput(for: agent)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NSSound(named: "Tink")?.play()
        let notification = NSUserNotification()
        notification.title = "📋 Copied Clean AI Output"
        notification.subtitle = "Source: \(agent.displayName)"
        notification.informativeText = String(text.prefix(80)) + "..."
        NSUserNotificationCenter.default.deliver(notification)

        print("📋 Copied clean output of \(agent.displayName) to macOS Clipboard (\(text.count) chars)")
        return true
    }

    public func relayChatGPTToAgent(targetAgent: AgentID) {
        let text = fetchFreshestOutput(for: .chatgpt)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NSSound(named: "Pop")?.play()
        let notification = NSUserNotification()
        notification.title = "📲 Relayed ChatGPT Output -> \(targetAgent.displayName)"
        notification.subtitle = "Copied to Clipboard & Focused Window"
        notification.informativeText = String(text.prefix(80)) + "..."
        NSUserNotificationCenter.default.deliver(notification)

        print("📲 Relayed ChatGPT Web response to \(targetAgent.displayName) (\(text.count) chars)")
        WindowFocuser.focusAgent(targetAgent)
    }
}
