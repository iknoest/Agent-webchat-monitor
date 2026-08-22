import Foundation

public struct TelegramConfig: Sendable, Equatable {
    public let botToken: String
    public let chatId: String

    public init(botToken: String, chatId: String) {
        self.botToken = botToken
        self.chatId = chatId
    }

    public var isConfigured: Bool {
        return !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var diagnosticSummary: String {
        let tokenStatus = !botToken.isEmpty ? "configured" : "missing"
        let chatStatus = !chatId.isEmpty ? "configured" : "missing"
        return "Telegram token: \(tokenStatus), Telegram chat ID: \(chatStatus)"
    }
}

public final class EnvConfigLoader: @unchecked Sendable {
    public static let shared = EnvConfigLoader()

    private let lock = NSLock()
    private var cachedConfig: TelegramConfig?

    private init() {
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }

        var token: String = ""
        var chatId: String = ""

        // 1. ProcessInfo environment
        let procEnv = ProcessInfo.processInfo.environment
        if let t = procEnv["TELEGRAM_BOT_TOKEN"], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let c = procEnv["TELEGRAM_CHAT_ID"], !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatId = c.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. ~/.config/AgentSignalBar/.env
        let userConfigEnvPath = NSString(string: "~/.config/AgentSignalBar/.env").expandingTildeInPath
        if token.isEmpty || chatId.isEmpty {
            let parsed = parseDotEnvFile(atPath: userConfigEnvPath)
            if token.isEmpty, let t = parsed["TELEGRAM_BOT_TOKEN"] { token = t }
            if chatId.isEmpty, let c = parsed["TELEGRAM_CHAT_ID"] { chatId = c }
        }

        // 3. Sibling .env next to repo-built AgentSignalBar.app bundle or working directory
        if token.isEmpty || chatId.isEmpty {
            // Sibling to app bundle
            let bundleURL = Bundle.main.bundleURL
            let appParentEnvURL = bundleURL.deletingLastPathComponent().appendingPathComponent(".env")
            let parsedSibling = parseDotEnvFile(atPath: appParentEnvURL.path)
            if token.isEmpty, let t = parsedSibling["TELEGRAM_BOT_TOKEN"] { token = t }
            if chatId.isEmpty, let c = parsedSibling["TELEGRAM_CHAT_ID"] { chatId = c }
        }

        if token.isEmpty || chatId.isEmpty {
            // Current working directory .env
            let cwdEnvPath = FileManager.default.currentDirectoryPath + "/.env"
            let parsedCwd = parseDotEnvFile(atPath: cwdEnvPath)
            if token.isEmpty, let t = parsedCwd["TELEGRAM_BOT_TOKEN"] { token = t }
            if chatId.isEmpty, let c = parsedCwd["TELEGRAM_CHAT_ID"] { chatId = c }
        }

        cachedConfig = TelegramConfig(botToken: token, chatId: chatId)
    }

    public func getTelegramConfig() -> TelegramConfig {
        lock.lock()
        defer { lock.unlock() }
        if let config = cachedConfig {
            return config
        }
        let config = TelegramConfig(botToken: "", chatId: "")
        cachedConfig = config
        return config
    }

    /// Sets explicit config for testing or programmatic injection
    public func setConfigForTesting(_ config: TelegramConfig?) {
        lock.lock()
        defer { lock.unlock() }
        cachedConfig = config
    }

    public func parseDotEnvFile(atPath path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return parseDotEnvString(content)
    }

    public func parseDotEnvString(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip enclosing quotes if present ("value" or 'value')
            if (val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2) ||
               (val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2) {
                val = String(val.dropFirst().dropLast())
            }

            if !key.isEmpty {
                result[key] = val
            }
        }
        return result
    }
}
