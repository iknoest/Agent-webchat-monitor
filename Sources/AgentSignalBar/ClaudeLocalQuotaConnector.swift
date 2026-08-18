import Foundation

public struct ClaudeResetObservation: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let relativeResetText: String
    public let relativeDurationSeconds: TimeInterval
    public let isApproximate: Bool
    public let derivedAbsoluteReset: Date
    public let formattedResetText: String
    public let source: String
    public let authority: String

    public init(
        observedAt: Date,
        relativeResetText: String,
        relativeDurationSeconds: TimeInterval,
        isApproximate: Bool = false,
        derivedAbsoluteReset: Date,
        formattedResetText: String,
        source: String = "claude_oauth_api",
        authority: String = "live_first_party"
    ) {
        self.observedAt = observedAt
        self.relativeResetText = relativeResetText
        self.relativeDurationSeconds = relativeDurationSeconds
        self.isApproximate = isApproximate
        self.derivedAbsoluteReset = derivedAbsoluteReset
        self.formattedResetText = formattedResetText
        self.source = source
        self.authority = authority
    }

    public var isExpired: Bool {
        return Date() >= derivedAbsoluteReset
    }
}

public struct ClaudeQuotaDebugInfo: Codable, Sendable {
    public let percentageSource: String
    public let resetSource: String
    public let apiAvailable: Bool
    public let cliAvailable: Bool
    public let fiveHourRemainingPercent: Double?
    public let fiveHourResetText: String?
    public let weeklyRemainingPercent: Double?
    public let weeklyResetText: String?
    public let lastSuccessfulRefresh: Date?
    public let lastError: String?

    public init(
        percentageSource: String,
        resetSource: String,
        apiAvailable: Bool,
        cliAvailable: Bool,
        fiveHourRemainingPercent: Double? = nil,
        fiveHourResetText: String? = nil,
        weeklyRemainingPercent: Double? = nil,
        weeklyResetText: String? = nil,
        lastSuccessfulRefresh: Date? = nil,
        lastError: String? = nil
    ) {
        self.percentageSource = percentageSource
        self.resetSource = resetSource
        self.apiAvailable = apiAvailable
        self.cliAvailable = cliAvailable
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.fiveHourResetText = fiveHourResetText
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.weeklyResetText = weeklyResetText
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastError = lastError
    }
}

// MARK: - Credentials

public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double? // Milliseconds since epoch
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Double? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }
}

public enum ClaudeCredentialSource: Sendable, Equatable {
    case file
    case keychain
    case environment
}

public struct ClaudeCredentialResult: @unchecked Sendable {
    public var oauth: ClaudeOAuthCredentials
    public let source: ClaudeCredentialSource
    public var fullData: [String: Any]

    public init(oauth: ClaudeOAuthCredentials, source: ClaudeCredentialSource, fullData: [String: Any]) {
        self.oauth = oauth
        self.source = source
        self.fullData = fullData
    }
}

public struct ClaudeCredentialLoader: Sendable {
    public static let keychainService = "Claude Code-credentials"
    public static let refreshBufferMs: Double = 5 * 60 * 1000 // 5 minutes

    public init() {}

    public func loadCredentials() -> ClaudeCredentialResult? {
        // 1. Keychain (Service: Claude Code-credentials)
        if let keychain = loadFromKeychain() {
            return keychain
        }

        // 2. File: ~/.claude/.credentials.json
        if let file = loadFromFile(path: NSString(string: "~/.claude/.credentials.json").expandingTildeInPath) {
            return file
        }

        // 3. File: ~/.claude.json
        if let file2 = loadFromFile(path: NSString(string: "~/.claude.json").expandingTildeInPath) {
            return file2
        }

        // 4. Environment variable CLAUDE_CODE_OAUTH_TOKEN
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envToken.isEmpty {
            let oauth = ClaudeOAuthCredentials(accessToken: envToken)
            return ClaudeCredentialResult(oauth: oauth, source: .environment, fullData: [:])
        }

        return nil
    }

    public func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt, oauth.refreshToken != nil else {
            return false
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + Self.refreshBufferMs >= expiresAt
    }

    public func saveCredentials(_ result: ClaudeCredentialResult) {
        if result.source == .environment { return }

        var updated = result.fullData
        var oauthDict = (updated["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauthDict["accessToken"] = result.oauth.accessToken
        if let rt = result.oauth.refreshToken { oauthDict["refreshToken"] = rt }
        if let exp = result.oauth.expiresAt { oauthDict["expiresAt"] = exp }
        if let sub = result.oauth.subscriptionType { oauthDict["subscriptionType"] = sub }
        if let tier = result.oauth.rateLimitTier { oauthDict["rateLimitTier"] = tier }
        updated["claudeAiOauth"] = oauthDict

        switch result.source {
        case .keychain:
            saveToKeychain(updated)
        case .file:
            saveToFile(data: updated, path: NSString(string: "~/.claude/.credentials.json").expandingTildeInPath)
        case .environment:
            break
        }
    }

    private func loadFromFile(path: String) -> ClaudeCredentialResult? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let oauthDict = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let rawAccessToken = oauthDict["accessToken"] as? String else { return nil }
        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { return nil }

        let oauth = ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauthDict["refreshToken"] as? String,
            expiresAt: (oauthDict["expiresAt"] as? NSNumber)?.doubleValue,
            subscriptionType: oauthDict["subscriptionType"] as? String,
            rateLimitTier: oauthDict["rateLimitTier"] as? String
        )
        return ClaudeCredentialResult(oauth: oauth, source: .file, fullData: json)
    }

    private func saveToFile(data: [String: Any], path: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadFromKeychain() -> ClaudeCredentialResult? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty,
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }

            let oauthDict = (json["claudeAiOauth"] as? [String: Any]) ?? json
            guard let rawAccessToken = oauthDict["accessToken"] as? String else { return nil }
            let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty else { return nil }

            let oauth = ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: oauthDict["refreshToken"] as? String,
                expiresAt: (oauthDict["expiresAt"] as? NSNumber)?.doubleValue,
                subscriptionType: oauthDict["subscriptionType"] as? String,
                rateLimitTier: oauthDict["rateLimitTier"] as? String
            )
            return ClaudeCredentialResult(oauth: oauth, source: .keychain, fullData: json)
        } catch {
            return nil
        }
    }

    private func saveToKeychain(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "add-generic-password",
            "-U",
            "-s", Self.keychainService,
            "-a", NSUserName(),
            "-w", jsonString
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }
}

// MARK: - Main Connector

public final class ClaudeLocalQuotaConnector: @unchecked Sendable {
    public static let shared = ClaudeLocalQuotaConnector()

    private let credentialLoader = ClaudeCredentialLoader()
    private let lock = NSLock()

    // API & Cache Constants
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let scopes = "user:profile user:inference user:sessions:claude_code"
    public static let cacheTTL: TimeInterval = 60.0 // 60s cache

    private var cachedUsage: AgentUsageData? = nil
    private var cachedAt: Date = .distantPast
    private var rateLimitUntil: Date? = nil
    private var lastError: String? = nil

    private var cached5hReset: ClaudeResetObservation? = nil
    private var cachedWeeklyReset: ClaudeResetObservation? = nil

    private init() {}

    // MARK: - Primary Fetch Flow

    public func fetchQuota(forceRefresh: Bool = false) -> AgentUsageData? {
        lock.lock()
        let now = Date()

        // Honor short in-memory cache if not forced
        if !forceRefresh, let cached = cachedUsage, now.timeIntervalSince(cachedAt) < Self.cacheTTL {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 1. Try Claude OAuth Usage API
        if let apiUsage = fetchFromOAuthAPI() {
            lock.lock()
            cachedUsage = apiUsage
            cachedAt = now
            lastError = nil
            lock.unlock()
            return apiUsage
        }

        // 2. Fallback to local plan-usage-history.json
        if let histUsage = fetchFromPlanUsageHistory() {
            lock.lock()
            cachedUsage = histUsage
            cachedAt = now
            lock.unlock()
            return histUsage
        }

        // 3. Fallback to Claude CLI /usage
        if let cliUsage = fetchFromCLI() {
            lock.lock()
            cachedUsage = cliUsage
            cachedAt = now
            lock.unlock()
            return cliUsage
        }

        // 4. Source unavailable
        lock.lock()
        var fallback = AgentUsageStore.shared.getUsage(for: .claude) ?? AgentUsageData(agent: .claude)
        fallback.isLiveSource = false
        fallback.freshness = fallback.quotaTimestamp != nil ? "Stale" : "Unavailable"
        fallback.lastUpdated = now
        cachedUsage = fallback
        cachedAt = now
        lock.unlock()
        return fallback
    }

    // MARK: - Priority 1: OAuth API

    public func fetchFromOAuthAPI() -> AgentUsageData? {
        let now = Date()

        // Check rate limiting
        lock.lock()
        if let limit = rateLimitUntil, now < limit {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard var credentials = credentialLoader.loadCredentials() else {
            return nil
        }

        // Refresh token if expired or near expiry
        if credentialLoader.needsRefresh(credentials.oauth) {
            if let refreshed = refreshToken(credentials) {
                credentials = refreshed
            } else {
                return nil
            }
        }

        // Call /api/oauth/usage
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentSignalBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data? = nil
        var responseCode = 0
        var retryAfterHeader: String? = nil

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                responseCode = http.statusCode
                retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
            }
            responseData = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10.0)

        // Handle 401: try refresh once if refresh token exists
        if responseCode == 401 && credentials.oauth.refreshToken != nil {
            if let refreshed = refreshToken(credentials) {
                return fetchFromOAuthAPIWithToken(accessToken: refreshed.oauth.accessToken)
            }
        }

        // Handle 429: Rate limited
        if responseCode == 429 {
            let backoff = parseRetryAfter(retryAfterHeader) ?? 300.0
            lock.lock()
            rateLimitUntil = now.addingTimeInterval(backoff)
            lastError = "Rate limited until \(rateLimitUntil!)"
            lock.unlock()
            return nil
        }

        guard responseCode == 200, let data = responseData else {
            lock.lock()
            lastError = "API response status \(responseCode)"
            lock.unlock()
            return nil
        }

        return parseUsageResponseData(data)
    }

    private func fetchFromOAuthAPIWithToken(accessToken: String) -> AgentUsageData? {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentSignalBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data? = nil
        var responseCode = 0

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                responseCode = http.statusCode
            }
            responseData = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10.0)

        guard responseCode == 200, let data = responseData else { return nil }
        return parseUsageResponseData(data)
    }

    public func refreshToken(_ credentials: ClaudeCredentialResult) -> ClaudeCredentialResult? {
        guard let refreshToken = credentials.oauth.refreshToken else { return nil }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data? = nil
        var responseCode = 0

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                responseCode = http.statusCode
            }
            responseData = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10.0)

        guard responseCode == 200, let data = responseData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            return nil
        }

        var updated = credentials
        updated.oauth.accessToken = newAccessToken
        if let newRt = json["refresh_token"] as? String {
            updated.oauth.refreshToken = newRt
        }
        if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue {
            updated.oauth.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }

        credentialLoader.saveCredentials(updated)
        return updated
    }

    // MARK: - JSON Response Parsing

    public func parseUsageResponseData(_ data: Data) -> AgentUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        let fhUtilization = (fiveHour?["utilization"] as? NSNumber)?.doubleValue
        let fhResetsAt = fiveHour?["resets_at"] as? String

        let sdUtilization = (sevenDay?["utilization"] as? NSNumber)?.doubleValue
        let sdResetsAt = sevenDay?["resets_at"] as? String

        let now = Date()
        let sessionResetText = ClaudeLocalQuotaConnector.formatResetText(from: fhResetsAt, now: now)
        let weeklyResetText = ClaudeLocalQuotaConnector.formatResetText(from: sdResetsAt, now: now)

        // Parse optional model specific limits
        var modelFamilies: [ModelFamilyQuota] = []
        if let sonnet = json["seven_day_sonnet"] as? [String: Any],
           let util = (sonnet["utilization"] as? NSNumber)?.doubleValue {
            let reset = ClaudeLocalQuotaConnector.formatResetText(from: sonnet["resets_at"] as? String, now: now)
            modelFamilies.append(ModelFamilyQuota(name: "Sonnet", weeklyLimitPercent: util, weeklyResetText: reset, isPercentUsed: true))
        }
        if let opus = json["seven_day_opus"] as? [String: Any],
           let util = (opus["utilization"] as? NSNumber)?.doubleValue {
            let reset = ClaudeLocalQuotaConnector.formatResetText(from: opus["resets_at"] as? String, now: now)
            modelFamilies.append(ModelFamilyQuota(name: "Opus", weeklyLimitPercent: util, weeklyResetText: reset, isPercentUsed: true))
        }

        return AgentUsageData(
            agent: .claude,
            sessionLimitPercent: fhUtilization ?? 0.0,
            sessionResetText: sessionResetText,
            weeklyLimitPercent: sdUtilization ?? 0.0,
            weeklyResetText: weeklyResetText,
            modelFamilies: modelFamilies,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "claude_oauth_api",
            sourceAuthority: "live_first_party",
            quotaTimestamp: now,
            lastSuccessfulRefresh: now,
            parserDecision: "parsed_live_oauth_api",
            freshness: "Fresh",
            lastUpdated: now
        )
    }

    // MARK: - Priority 2: Plan Usage History Fallback

    public func fetchFromPlanUsageHistory() -> AgentUsageData? {
        let path = NSString(string: "~/Library/Application Support/Claude/plan-usage-history.json").expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let lastSample = samples.last,
              let uDict = lastSample["u"] as? [String: Any] else {
            return nil
        }

        let fh = (uDict["fh"] as? NSNumber)?.doubleValue ?? 0.0
        let sd = (uDict["sd"] as? NSNumber)?.doubleValue ?? 0.0

        var sampleDate: Date? = nil
        if let lastTimestampMs = (lastSample["t"] as? NSNumber)?.doubleValue {
            sampleDate = Date(timeIntervalSince1970: lastTimestampMs / 1000.0)
        }

        let now = Date()
        let isStale = sampleDate != nil && now.timeIntervalSince(sampleDate!) > 86400

        return AgentUsageData(
            agent: .claude,
            sessionLimitPercent: fh,
            sessionResetText: nil, // No fabricated reset time from local history
            weeklyLimitPercent: sd,
            weeklyResetText: nil,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "claude_plan_usage_history",
            sourceAuthority: "live_local_file",
            quotaTimestamp: sampleDate,
            lastSuccessfulRefresh: now,
            parserDecision: isStale ? "stale_sample_history" : "parsed_local_history",
            freshness: isStale ? "Stale" : "Fresh",
            lastUpdated: now
        )
    }

    // MARK: - Priority 3: Claude CLI Fallback

    public func findClaudeBinary() -> String? {
        let candidates = [
            "/Users/ava/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["claude"]
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

    public func fetchFromCLI() -> AgentUsageData? {
        guard let binaryPath = findClaudeBinary() else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = ["/usage", "--allowed-tools", ""]

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = inPipe

        // Close stdin immediately so CLI does not wait
        try? inPipe.fileHandleForWriting.close()

        do {
            try task.run()
        } catch {
            return nil
        }

        let pid = task.processIdentifier
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            task.waitUntilExit()
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + 5.0)
        if timeoutResult == .timedOut {
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
            kill(pid, SIGKILL)
            task.waitUntilExit()
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        return parseCLIUsageOutput(text)
    }

    public func parseCLIUsageOutput(_ text: String) -> AgentUsageData? {
        let lines = text.components(separatedBy: .newlines)
        var sessionPercent: Double? = nil
        var sessionReset: String? = nil
        var weeklyPercent: Double? = nil
        var weeklyReset: String? = nil

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("current session") {
                if let match = line.range(of: "(\\d+(?:\\.\\d+)?)%\\s*used", options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
                    sessionPercent = Double(numStr)
                }
                if let resetMatch = line.range(of: "resets\\s+(.*)", options: .regularExpression) {
                    let rawReset = String(line[resetMatch])
                    sessionReset = formatCLIRawReset(rawReset)
                }
            } else if lower.contains("current week") {
                if let match = line.range(of: "(\\d+(?:\\.\\d+)?)%\\s*used", options: .regularExpression) {
                    let numStr = line[match].replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
                    weeklyPercent = Double(numStr)
                }
                if let resetMatch = line.range(of: "resets\\s+(.*)", options: .regularExpression) {
                    let rawReset = String(line[resetMatch])
                    weeklyReset = formatCLIRawReset(rawReset)
                }
            }
        }

        guard sessionPercent != nil || weeklyPercent != nil else { return nil }
        let now = Date()

        return AgentUsageData(
            agent: .claude,
            sessionLimitPercent: sessionPercent ?? 0.0,
            sessionResetText: sessionReset,
            weeklyLimitPercent: weeklyPercent ?? 0.0,
            weeklyResetText: weeklyReset,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "claude_cli_usage",
            sourceAuthority: "live_cli_fallback",
            quotaTimestamp: now,
            lastSuccessfulRefresh: now,
            parserDecision: "parsed_cli_output",
            freshness: "Fresh",
            lastUpdated: now
        )
    }

    private func formatCLIRawReset(_ raw: String) -> String {
        // e.g. "resets Aug 24 at 10:59pm (Europe/Amsterdam)" -> parse date or clean up
        let now = Date()
        let cleaned = raw.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
                         .replacingOccurrences(of: "^resets\\s*", with: "", options: .regularExpression)
                         .replacingOccurrences(of: "\\s+at\\s+", with: " ", options: .regularExpression)
                         .trimmingCharacters(in: .whitespaces)

        // Try parsing "Aug 24 10:59pm" or "Aug 24 22:59"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d h:mma"

        var parsedDate = formatter.date(from: cleaned)
        if parsedDate == nil {
            formatter.dateFormat = "MMM d HH:mm"
            parsedDate = formatter.date(from: cleaned)
        }

        if let d = parsedDate {
            let calendar = Calendar.current
            var comps = calendar.dateComponents([.month, .day, .hour, .minute], from: d)
            comps.year = calendar.component(.year, from: now)
            if let resolved = calendar.date(from: comps) {
                let target = resolved < now ? calendar.date(byAdding: .year, value: 1, to: resolved)! : resolved
                return "resets \(ClaudeLocalQuotaConnector.formatResetDateTime(date: target, now: now))"
            }
        }

        return raw.hasPrefix("resets ") ? raw : "resets \(raw)"
    }

    // MARK: - Date Parsing & Formatting Helpers

    public static func parseISODate(_ isoString: String?) -> Date? {
        guard let isoString = isoString, !isoString.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            return date
        }

        // Sub-second precision with >3 fraction digits (e.g. 2026-08-24T21:00:00.346450+00:00)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let date = df.date(from: isoString) {
            return date
        }

        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return df.date(from: isoString)
    }

    public static func formatResetDateTime(
        date: Date,
        now: Date = Date(),
        isApproximate: Bool = false,
        timeZone: TimeZone = .current
    ) -> String {
        let calendar = Calendar.current
        let diff = max(0, date.timeIntervalSince(now))

        if diff <= 0 {
            return "soon"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: date)

        let relString: String
        let clockPrefix: String

        if isApproximate {
            let hours = max(1, Int(round(diff / 3600.0)))
            if hours >= 24 {
                let days = max(1, Int(round(diff / 86400.0)))
                relString = "in ~\(days)d"
            } else {
                relString = "in ~\(hours)h"
            }
            clockPrefix = "~\(timeStr)"
        } else {
            if diff < 3600 {
                let mins = max(1, Int(round(diff / 60.0)))
                relString = "in \(mins)m"
            } else if diff < 86400 {
                let hours = Int(diff / 3600.0)
                let mins = (Int(diff) / 60) % 60
                if mins > 0 {
                    relString = "in \(hours)h \(mins)m"
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
            clockPrefix = timeStr
        }

        let dayPrefix: String
        if calendar.isDate(date, inSameDayAs: now) {
            dayPrefix = "today"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = "MMM d"
            dayPrefix = dateFormatter.string(from: date)
        }

        return "\(dayPrefix) \(clockPrefix) (\(relString))"
    }

    public static func formatResetText(from isoString: String?, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let isoString = isoString, !isoString.isEmpty else { return nil }
        guard let date = parseISODate(isoString) else { return nil }
        return "resets \(formatResetDateTime(date: date, now: now, timeZone: timeZone))"
    }

    private func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let val = value?.trimmingCharacters(in: .whitespaces), !val.isEmpty else { return nil }
        if let sec = TimeInterval(val), sec > 0 { return sec }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = formatter.date(from: val) {
            let delta = d.timeIntervalSinceNow
            return delta > 0 ? delta : nil
        }
        return nil
    }

    // MARK: - Relative Duration Parsing & Legacy Observation (Retained for Tests & Formatters)

    public struct ParsedDuration: Equatable {
        public let seconds: TimeInterval
        public let isApproximate: Bool
    }

    public static func parseRelativeResetDurationDetails(from text: String) -> ParsedDuration? {
        let lower = text.lowercased()
        guard lower.contains("reset") else { return nil }

        var totalSeconds: TimeInterval = 0
        var matchedAny = false
        var hasMinutes = false

        if let match = lower.range(of: "(\\d+)\\s*(?:d|day|days)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let days = Double(numStr) {
                totalSeconds += days * 86400
                matchedAny = true
            }
        }
        if let match = lower.range(of: "(\\d+)\\s*(?:h|hr|hrs|hour|hours)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let hours = Double(numStr) {
                totalSeconds += hours * 3600
                matchedAny = true
            }
        }
        if let match = lower.range(of: "(\\d+)\\s*(?:m|min|mins|minute|minutes)(?!s)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let mins = Double(numStr) {
                totalSeconds += mins * 60
                matchedAny = true
                hasMinutes = true
            }
        }

        guard matchedAny && totalSeconds > 0 else { return nil }
        return ParsedDuration(seconds: totalSeconds, isApproximate: !hasMinutes)
    }

    public static func parseRelativeResetDuration(from text: String) -> TimeInterval? {
        return parseRelativeResetDurationDetails(from: text)?.seconds
    }

    public static func deriveResetObservation(
        relativeText: String,
        observedAt: Date = Date(),
        now: Date = Date(),
        source: String = "claude_oauth_api"
    ) -> ClaudeResetObservation? {
        guard let parsed = parseRelativeResetDurationDetails(from: relativeText) else {
            return nil
        }
        let derivedDate = observedAt.addingTimeInterval(parsed.seconds)
        let formattedDate = formatResetDateTime(date: derivedDate, now: now, isApproximate: parsed.isApproximate)
        let formattedReset = "resets \(formattedDate)"

        return ClaudeResetObservation(
            observedAt: observedAt,
            relativeResetText: relativeText,
            relativeDurationSeconds: parsed.seconds,
            isApproximate: parsed.isApproximate,
            derivedAbsoluteReset: derivedDate,
            formattedResetText: formattedReset,
            source: source,
            authority: "live_first_party"
        )
    }

    public func setCachedObservations(sessionReset: ClaudeResetObservation?, weeklyReset: ClaudeResetObservation?) {
        lock.lock()
        cached5hReset = sessionReset
        cachedWeeklyReset = weeklyReset
        lock.unlock()
    }

    public func getResetMetadata() -> (sessionResetText: String?, weeklyResetText: String?) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        var sText: String? = nil
        var wText: String? = nil

        if let s = cached5hReset {
            if now >= s.derivedAbsoluteReset {
                cached5hReset = nil
            } else {
                let relativeFormatted = ClaudeLocalQuotaConnector.formatResetDateTime(date: s.derivedAbsoluteReset, now: now, isApproximate: s.isApproximate)
                sText = "resets \(relativeFormatted)"
            }
        }
        if let w = cachedWeeklyReset {
            if now >= w.derivedAbsoluteReset {
                cachedWeeklyReset = nil
            } else {
                let relativeFormatted = ClaudeLocalQuotaConnector.formatResetDateTime(date: w.derivedAbsoluteReset, now: now, isApproximate: w.isApproximate)
                wText = "resets \(relativeFormatted)"
            }
        }

        return (sText, wText)
    }

    // MARK: - Debug & Diagnostic Info

    public func getDebugInfo() -> ClaudeQuotaDebugInfo {
        lock.lock()
        defer { lock.unlock() }

        let usage = cachedUsage ?? AgentUsageStore.shared.getUsage(for: .claude)
        let creds = credentialLoader.loadCredentials()
        let cli = findClaudeBinary()

        return ClaudeQuotaDebugInfo(
            percentageSource: usage?.quotaSource ?? "none",
            resetSource: (usage?.sessionResetText != nil || usage?.weeklyResetText != nil) ? (usage?.quotaSource ?? "none") : "none",
            apiAvailable: creds != nil,
            cliAvailable: cli != nil,
            fiveHourRemainingPercent: usage?.sessionRemainingPercent,
            fiveHourResetText: usage?.sessionResetText,
            weeklyRemainingPercent: usage?.weeklyRemainingPercent,
            weeklyResetText: usage?.weeklyResetText,
            lastSuccessfulRefresh: usage?.lastSuccessfulRefresh,
            lastError: lastError
        )
    }
}
