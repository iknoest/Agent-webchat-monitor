import Foundation

public enum TelegramPrivacySafeContext {
    /// Resolves a privacy-safe project or workspace context string for Telegram notifications and commands.
    /// NEVER returns prompt text, pasted instructions, attachment paths, source code, or private URLs.
    public static func resolveSafeProjectContext(
        agent: AgentID,
        session: AgentSessionInfo?
    ) -> String {
        // 1. If cwd is present, extract its safe directory basename
        if let rawCwd = session?.cwd, !rawCwd.isEmpty {
            let folderName = (rawCwd as NSString).lastPathComponent
            if isSafeProjectName(folderName) {
                return folderName
            }
        }

        // 2. If title is a safe short project identifier (not prompt text or file contents)
        if let rawTitle = session?.title, isSafeProjectName(rawTitle) {
            return rawTitle
        }

        // 3. Provider-native neutral fallback
        switch agent {
        case .chatgpt:
            return "ChatGPT Web"
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex Desktop"
        case .antigravity:
            return "Antigravity"
        case .copilot:
            return "GitHub Copilot"
        }
    }

    /// Verifies if a string is a safe project/directory name and NOT a leaked prompt, path, or code snippet.
    public static func isSafeProjectName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 45 { return false }

        // Must not contain newlines or carriage returns
        if trimmed.contains("\n") || trimmed.contains("\r") { return false }

        // Must not contain prompt indicators or code markers
        if trimmed.contains("#") || trimmed.contains("SELECT ") || trimmed.contains("WHERE ") || trimmed.contains("import ") {
            return false
        }
        if trimmed.contains("{") || trimmed.contains("}") || trimmed.contains(";") || trimmed.contains("(") || trimmed.contains(")") {
            return false
        }

        // Must not contain URL or absolute file paths
        if trimmed.contains("http://") || trimmed.contains("https://") || trimmed.contains("file://") || trimmed.hasPrefix("/Users/") || trimmed.hasPrefix("~/") {
            return false
        }

        // Must not start with common prompt phrases
        let lower = trimmed.lowercased()
        if lower.hasPrefix("files pasted") || lower.hasPrefix("pasted") || lower.hasPrefix("please ") || lower.hasPrefix("can you") || lower.hasPrefix("write a") || lower.hasPrefix("how to") {
            return false
        }

        return true
    }

    /// Sanitizes an attention reason for Telegram outbound messages to guarantee no prompt/code leakage.
    public static func sanitizeAttentionReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "User input or permission required" }
        if trimmed.contains("\n") || trimmed.contains("#") || trimmed.count > 80 || trimmed.contains("SELECT ") || trimmed.contains("/Users/") {
            return "User approval or input requested"
        }
        return trimmed
    }
}
