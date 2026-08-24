import Foundation

public struct TestEnvironment: Sendable {
    private static let lock = NSLock()
    private static var _isTestMode: Bool = false

    public static var isTestRuntime: Bool {
        lock.lock()
        defer { lock.unlock() }
        if _isTestMode { return true }
        let env = ProcessInfo.processInfo.environment
        if env["AGENT_BRIDGE_TEST_MODE"] != nil ||
           env["XCTestConfigurationFilePath"] != nil ||
           env["SWIFT_DETERMINISTIC_TEST_MODE"] != nil {
            return true
        }
        let procName = ProcessInfo.processInfo.processName
        if procName == "Stage1TestRunner" || procName == "xctest" {
            return true
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--test-runner") || args.contains("Stage1TestRunner") {
            return true
        }
        return false
    }

    public static func enableTestMode() {
        lock.lock()
        defer { lock.unlock() }
        _isTestMode = true
    }

    public static func disableTestModeForTesting() {
        lock.lock()
        defer { lock.unlock() }
        _isTestMode = false
    }
}

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
    private var isExplicitTestConfig: Bool = false

    private init() {
        reload()
    }

    public static var stableUserEnvPath: String {
        return NSString(string: "~/.config/AgentSignalBar/.env").expandingTildeInPath
    }

    public static var legacyUserEnvPath: String {
        return NSString(string: "~/.config/agent_signal_bar/.env").expandingTildeInPath
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }

        if TestEnvironment.isTestRuntime {
            // Test Mode Isolation: Never load production environment or .env files from disk during tests
            if !isExplicitTestConfig {
                cachedConfig = TelegramConfig(botToken: "", chatId: "")
            }
            return
        }

        var token: String = ""
        var chatId: String = ""

        // 1. ProcessInfo environment (highest priority)
        let procEnv = ProcessInfo.processInfo.environment
        if let t = procEnv["TELEGRAM_BOT_TOKEN"], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let c = procEnv["TELEGRAM_CHAT_ID"], !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatId = c.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Stable user config location: ~/.config/AgentSignalBar/.env
        let stableEnvPath = Self.stableUserEnvPath
        if token.isEmpty || chatId.isEmpty {
            let parsed = parseDotEnvFile(atPath: stableEnvPath)
            if token.isEmpty, let t = parsed["TELEGRAM_BOT_TOKEN"] { token = t }
            if chatId.isEmpty, let c = parsed["TELEGRAM_CHAT_ID"] { chatId = c }
        }

        // 2b. Legacy user config fallback: ~/.config/agent_signal_bar/.env
        if token.isEmpty || chatId.isEmpty {
            let parsedLegacy = parseDotEnvFile(atPath: Self.legacyUserEnvPath)
            if token.isEmpty, let t = parsedLegacy["TELEGRAM_BOT_TOKEN"] { token = t }
            if chatId.isEmpty, let c = parsedLegacy["TELEGRAM_CHAT_ID"] { chatId = c }
        }

        // 3. Development / repo-local fallback sources (sibling to app bundle, cwd, or known dev paths)
        var fallbackToken = ""
        var fallbackChatId = ""

        if token.isEmpty || chatId.isEmpty {
            // Sibling to app bundle
            let bundleURL = Bundle.main.bundleURL
            let appParentEnvURL = bundleURL.deletingLastPathComponent().appendingPathComponent(".env")
            let parsedSibling = parseDotEnvFile(atPath: appParentEnvURL.path)
            if fallbackToken.isEmpty, let t = parsedSibling["TELEGRAM_BOT_TOKEN"] { fallbackToken = t }
            if fallbackChatId.isEmpty, let c = parsedSibling["TELEGRAM_CHAT_ID"] { fallbackChatId = c }
        }

        if token.isEmpty || chatId.isEmpty {
            // Current working directory .env
            let cwdEnvPath = FileManager.default.currentDirectoryPath + "/.env"
            let parsedCwd = parseDotEnvFile(atPath: cwdEnvPath)
            if fallbackToken.isEmpty, let t = parsedCwd["TELEGRAM_BOT_TOKEN"] { fallbackToken = t }
            if fallbackChatId.isEmpty, let c = parsedCwd["TELEGRAM_CHAT_ID"] { fallbackChatId = c }
        }

        if token.isEmpty && !fallbackToken.isEmpty {
            token = fallbackToken
        }
        if chatId.isEmpty && !fallbackChatId.isEmpty {
            chatId = fallbackChatId
        }

        // 4. Safe migration: If stable config ~/.config/AgentSignalBar/.env is missing credentials, but a fallback has them, persist securely to stable path
        if !token.isEmpty && !chatId.isEmpty {
            migrateToStableEnvIfNeeded(token: token, chatId: chatId)
        }

        cachedConfig = TelegramConfig(botToken: token, chatId: chatId)
    }

    public func migrateToStableEnvIfNeeded(token: String, chatId: String) {
        let stableEnvPath = Self.stableUserEnvPath
        let fm = FileManager.default
        let dirPath = NSString(string: stableEnvPath).deletingLastPathComponent

        // Check if stable file already has both credentials
        let existing = parseDotEnvFile(atPath: stableEnvPath)
        if existing["TELEGRAM_BOT_TOKEN"] == token && existing["TELEGRAM_CHAT_ID"] == chatId {
            return // Already synchronized
        }

        do {
            if !fm.fileExists(atPath: dirPath) {
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }

            var lines: [String] = []
            if fm.fileExists(atPath: stableEnvPath), let content = try? String(contentsOfFile: stableEnvPath, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.hasPrefix("TELEGRAM_BOT_TOKEN=") && !trimmed.hasPrefix("TELEGRAM_CHAT_ID=") && !trimmed.isEmpty {
                        lines.append(line)
                    }
                }
            }

            lines.append("TELEGRAM_BOT_TOKEN=\(token)")
            lines.append("TELEGRAM_CHAT_ID=\(chatId)")
            let outContent = lines.joined(separator: "\n") + "\n"

            try outContent.write(toFile: stableEnvPath, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stableEnvPath)
            print("🔒 Safely synchronized Telegram configuration to stable user config path")
        } catch {
            print("⚠️ Failed to write to stable .env path: \(error.localizedDescription)")
        }
    }

    public func getTelegramConfig() -> TelegramConfig {
        lock.lock()
        defer { lock.unlock() }
        if let config = cachedConfig {
            return config
        }
        if TestEnvironment.isTestRuntime {
            let emptyConfig = TelegramConfig(botToken: "", chatId: "")
            cachedConfig = emptyConfig
            return emptyConfig
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
        isExplicitTestConfig = (config != nil)
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
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            var val = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // If value starts with a quote, extract up to closing quote
            if val.hasPrefix("\"") && val.count >= 2 {
                let rest = val.dropFirst()
                if let endQuoteIdx = rest.firstIndex(of: "\"") {
                    val = String(rest[..<endQuoteIdx])
                } else if val.hasSuffix("\"") {
                    val = String(val.dropFirst().dropLast())
                }
            } else if val.hasPrefix("'") && val.count >= 2 {
                let rest = val.dropFirst()
                if let endQuoteIdx = rest.firstIndex(of: "'") {
                    val = String(rest[..<endQuoteIdx])
                } else if val.hasSuffix("'") {
                    val = String(val.dropFirst().dropLast())
                }
            } else {
                // Unquoted value: strip trailing inline comments starting with '#'
                if let commentIdx = val.firstIndex(of: "#") {
                    val = String(val[..<commentIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            val = val.trimmingCharacters(in: .whitespacesAndNewlines)

            if !key.isEmpty {
                result[key] = val
            }
        }
        return result
    }
}
