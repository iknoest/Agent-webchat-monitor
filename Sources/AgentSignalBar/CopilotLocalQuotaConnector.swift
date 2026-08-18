import Foundation

public final class CopilotLocalQuotaConnector {
    public static let shared = CopilotLocalQuotaConnector()

    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoDateFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init() {}

    public func fetchCopilotUsage(timeoutSeconds: TimeInterval = 2.0) -> AgentUsageData? {
        // Priority 1: Bounded gh CLI execution (gh api /copilot_internal/user)
        if let cliJSON = executeGhCopilotUserAPI(timeoutSeconds: timeoutSeconds),
           let data = cliJSON.data(using: .utf8),
           let usage = parseUsageResponseData(data) {
            return usage
        }

        // Priority 2: Direct authenticated request using Keychain / gh token
        if let token = getGitHubToken(timeoutSeconds: timeoutSeconds), !token.isEmpty,
           let data = fetchDirectCopilotUserAPI(token: token, timeoutSeconds: timeoutSeconds),
           let usage = parseUsageResponseData(data) {
            return usage
        }

        return nil
    }

    public func parseUsageResponseData(_ data: Data, now: Date = Date()) -> AgentUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var usage = AgentUsageData(agent: .copilot)
        usage.isLiveSource = true
        usage.quotaSource = "copilot_internal_user"
        usage.quotaTimestamp = now
        usage.freshness = "Fresh"
        usage.isPercentUsed = false // Percent is already remaining

        let resetUTC = json["quota_reset_date_utc"] as? String ?? json["quota_reset_date"] as? String
        var formattedReset: String? = nil
        if let rUTC = resetUTC, !rUTC.isEmpty {
            formattedReset = Self.formatResetText(from: rUTC, now: now)
        }
        usage.sessionResetText = formattedReset

        var families: [ModelFamilyQuota] = []

        if let snapshots = json["quota_snapshots"] as? [String: [String: Any]] {
            if let chat = snapshots["chat"] {
                let remainingPct = chat["percent_remaining"] as? Double
                let creditsUsed = chat["credits_used"] as? Double ?? (chat["credits_used"] as? Int).map { Double($0) }
                let entitlement = chat["entitlement"] as? Double ?? (chat["entitlement"] as? Int).map { Double($0) }

                if let rem = remainingPct {
                    usage.sessionLimitPercent = rem
                    families.append(ModelFamilyQuota(
                        name: "Chat",
                        sessionLimitPercent: rem,
                        sessionResetText: formattedReset,
                        isPercentUsed: false
                    ))
                } else if let used = creditsUsed, let total = entitlement, total > 0 {
                    let calculatedRem = max(0.0, min(100.0, (1.0 - (used / total)) * 100.0))
                    usage.sessionLimitPercent = calculatedRem
                    families.append(ModelFamilyQuota(
                        name: "Chat",
                        sessionLimitPercent: calculatedRem,
                        sessionResetText: formattedReset,
                        isPercentUsed: false
                    ))
                }
            }

            if let completions = snapshots["completions"] {
                if let rem = completions["percent_remaining"] as? Double {
                    families.append(ModelFamilyQuota(
                        name: "Completions",
                        sessionLimitPercent: rem,
                        sessionResetText: formattedReset,
                        isPercentUsed: false
                    ))
                }
            }

            if let premium = snapshots["premium_interactions"], (premium["has_quota"] as? Bool) == true {
                if let rem = premium["percent_remaining"] as? Double {
                    families.append(ModelFamilyQuota(
                        name: "Premium",
                        sessionLimitPercent: rem,
                        sessionResetText: formattedReset,
                        isPercentUsed: false
                    ))
                }
            }
        }

        usage.modelFamilies = families

        guard usage.sessionLimitPercent != nil || !families.isEmpty else {
            return nil
        }

        return usage
    }

    public static func formatResetText(from isoString: String, now: Date = Date()) -> String? {
        let clean = isoString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let formatterFractional = ISO8601DateFormatter()
        formatterFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formatterStandard = ISO8601DateFormatter()
        formatterStandard.formatOptions = [.withInternetDateTime]

        let formatterDateOnly = DateFormatter()
        formatterDateOnly.dateFormat = "yyyy-MM-dd"
        formatterDateOnly.timeZone = TimeZone(secondsFromGMT: 0)

        guard let resetDate = formatterFractional.date(from: clean)
                ?? formatterStandard.date(from: clean)
                ?? formatterDateOnly.date(from: clean) else {
            return "resets \(clean)"
        }

        let diff = resetDate.timeIntervalSince(now)
        guard diff > 0 else {
            return "resets soon"
        }

        let totalHours = Int(diff) / 3600
        let days = totalHours / 24
        let remainingHours = totalHours % 24
        let totalMinutes = Int(diff) / 60

        let relativeStr: String
        if days > 0 {
            relativeStr = "\(days)d"
        } else if totalHours > 0 {
            relativeStr = "\(totalHours)h"
        } else {
            relativeStr = "\(max(1, totalMinutes))m"
        }

        let cal = Calendar.current
        let isToday = cal.isDate(resetDate, inSameDayAs: now)
        let isTomorrow = cal.isDate(resetDate, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now) ?? now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timePart = timeFormatter.string(from: resetDate)

        if isToday {
            return "resets today \(timePart) (in \(relativeStr))"
        } else if isTomorrow {
            return "resets tomorrow \(timePart) (in \(relativeStr))"
        } else {
            let monthDayFormatter = DateFormatter()
            monthDayFormatter.dateFormat = "MMM d"
            let monthDay = monthDayFormatter.string(from: resetDate)
            if days >= 1 {
                return "resets \(monthDay) (in \(relativeStr))"
            } else {
                return "resets \(monthDay) \(timePart) (in \(relativeStr))"
            }
        }
    }

    private func executeGhCopilotUserAPI(timeoutSeconds: TimeInterval) -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        guard let ghPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }

        return AutoMonitor.shared.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: ghPath),
            arguments: ["api", "/copilot_internal/user"],
            timeoutSeconds: timeoutSeconds
        )
    }

    private func getGitHubToken(timeoutSeconds: TimeInterval) -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        guard let ghPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }

        let output = AutoMonitor.shared.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: ghPath),
            arguments: ["auth", "token"],
            timeoutSeconds: timeoutSeconds
        )

        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchDirectCopilotUserAPI(token: String, timeoutSeconds: TimeInterval) -> Data? {
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentSignalBar/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var resultData: Data? = nil
        let sem = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                resultData = data
            }
            sem.signal()
        }
        task.resume()

        _ = sem.wait(timeout: .now() + timeoutSeconds)
        return resultData
    }
}
