import Foundation
import Cocoa
import ApplicationServices

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
        source: String = "claude_native_menu_ax",
        authority: String = "ui_derived_first_party"
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

public struct ClaudeResetDebugInfo: Codable, Sendable {
    public let agentSignalBarAXTrusted: Bool
    public let claudeRunning: Bool
    public let usageControlFound: Bool
    public let popoverOpened: Bool
    public let fiveHourRawReset: String?
    public let weeklyRawReset: String?
    public let fiveHourParsedReset: String?
    public let weeklyParsedReset: String?
    public let percentageSource: String
    public let resetSource: String
    public let lastError: String?
    public let windowsCount: Int
    public let scannedStringsCount: Int
    public let candidateQuotaStrings: [String]

    public init(
        agentSignalBarAXTrusted: Bool,
        claudeRunning: Bool,
        usageControlFound: Bool,
        popoverOpened: Bool,
        fiveHourRawReset: String?,
        weeklyRawReset: String?,
        fiveHourParsedReset: String?,
        weeklyParsedReset: String?,
        percentageSource: String = "claude_plan_usage_history",
        resetSource: String = "claude_native_menu_ax",
        lastError: String? = nil,
        windowsCount: Int = 0,
        scannedStringsCount: Int = 0,
        candidateQuotaStrings: [String] = []
    ) {
        self.agentSignalBarAXTrusted = agentSignalBarAXTrusted
        self.claudeRunning = claudeRunning
        self.usageControlFound = usageControlFound
        self.popoverOpened = popoverOpened
        self.fiveHourRawReset = fiveHourRawReset
        self.weeklyRawReset = weeklyRawReset
        self.fiveHourParsedReset = fiveHourParsedReset
        self.weeklyParsedReset = weeklyParsedReset
        self.percentageSource = percentageSource
        self.resetSource = resetSource
        self.lastError = lastError
        self.windowsCount = windowsCount
        self.scannedStringsCount = scannedStringsCount
        self.candidateQuotaStrings = candidateQuotaStrings
    }
}

public final class ClaudeLocalQuotaConnector: @unchecked Sendable {
    public static let shared = ClaudeLocalQuotaConnector()

    private var cached5hReset: ClaudeResetObservation? = nil
    private var cachedWeeklyReset: ClaudeResetObservation? = nil
    private var lastRefreshAttempt: Date = .distantPast
    private var lastDebugInfo: ClaudeResetDebugInfo? = nil
    private let lock = NSLock()

    private init() {}

    public struct ParsedDuration: Equatable {
        public let seconds: TimeInterval
        public let isApproximate: Bool
    }

    // Parse relative duration details from strings like "resets 3h", "resets 42m", "17% · resets 3h", "Resets in 3 hr 36 min", "Resets in 1 hr 26 min"
    public static func parseRelativeResetDurationDetails(from text: String) -> ParsedDuration? {
        let lower = text.lowercased()
        guard lower.contains("reset") else { return nil }

        var totalSeconds: TimeInterval = 0
        var matchedAny = false
        var hasMinutes = false
        var hasHours = false
        var hasDays = false

        // Days
        if let match = lower.range(of: "(\\d+)\\s*(?:d|day|days)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let days = Double(numStr) {
                totalSeconds += days * 86400
                matchedAny = true
                hasDays = true
            }
        }

        // Hours
        if let match = lower.range(of: "(\\d+)\\s*(?:h|hr|hrs|hour|hours)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let hours = Double(numStr) {
                totalSeconds += hours * 3600
                matchedAny = true
                hasHours = true
            }
        }

        // Minutes
        if let match = lower.range(of: "(\\d+)\\s*(?:m|min|mins|minute|minutes)(?!s)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let mins = Double(numStr) {
                totalSeconds += mins * 60
                matchedAny = true
                hasMinutes = true
            }
        }

        guard matchedAny && totalSeconds > 0 else { return nil }
        let isApproximate = !hasMinutes
        return ParsedDuration(seconds: totalSeconds, isApproximate: isApproximate)
    }

    public static func parseRelativeResetDuration(from text: String) -> TimeInterval? {
        return parseRelativeResetDurationDetails(from: text)?.seconds
    }

    // Format reset timestamp with rounded/approximate vs exact precision semantics
    public static func formatClaudeResetDateTime(
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

    // Derive absolute reset date and format according to AgentSignalBar standardized 24-hour style
    public static func deriveResetObservation(
        relativeText: String,
        observedAt: Date = Date(),
        now: Date = Date(),
        source: String = "claude_native_menu_ax"
    ) -> ClaudeResetObservation? {
        guard let parsed = parseRelativeResetDurationDetails(from: relativeText) else {
            return nil
        }
        let derivedDate = observedAt.addingTimeInterval(parsed.seconds)
        let formattedDate = formatClaudeResetDateTime(date: derivedDate, now: now, isApproximate: parsed.isApproximate)
        let formattedReset = "resets \(formattedDate)"

        return ClaudeResetObservation(
            observedAt: observedAt,
            relativeResetText: relativeText,
            relativeDurationSeconds: parsed.seconds,
            isApproximate: parsed.isApproximate,
            derivedAbsoluteReset: derivedDate,
            formattedResetText: formattedReset,
            source: source,
            authority: "ui_derived_first_party"
        )
    }

    public static func promptAccessibilityPermissionIfUntrusted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Explicit Bounded Refresh: Inspects Claude Desktop UI for live 5-hour and Weekly reset strings
    @discardableResult
    public func refreshClaudeNativeAXReset() -> (sessionReset: ClaudeResetObservation?, weeklyReset: ClaudeResetObservation?) {
        lock.lock()
        defer { lock.unlock() }

        let isTrusted = AXIsProcessTrusted()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        let allApps = NSWorkspace.shared.runningApplications
        let app = apps.first ?? allApps.first(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName == "Claude" })

        guard isTrusted else {
            lastDebugInfo = ClaudeResetDebugInfo(
                agentSignalBarAXTrusted: false,
                claudeRunning: app != nil,
                usageControlFound: false,
                popoverOpened: false,
                fiveHourRawReset: cached5hReset?.relativeResetText,
                weeklyRawReset: cachedWeeklyReset?.relativeResetText,
                fiveHourParsedReset: cached5hReset?.formattedResetText,
                weeklyParsedReset: cachedWeeklyReset?.formattedResetText,
                lastError: "AgentSignalBar lacks macOS Accessibility permission (TCC). Grant Accessibility in System Settings > Privacy & Security > Accessibility."
            )
            return (cached5hReset, cachedWeeklyReset)
        }

        guard let claudeApp = app else {
            lastDebugInfo = ClaudeResetDebugInfo(
                agentSignalBarAXTrusted: true,
                claudeRunning: false,
                usageControlFound: false,
                popoverOpened: false,
                fiveHourRawReset: cached5hReset?.relativeResetText,
                weeklyRawReset: cachedWeeklyReset?.relativeResetText,
                fiveHourParsedReset: cached5hReset?.formattedResetText,
                weeklyParsedReset: cachedWeeklyReset?.formattedResetText,
                lastError: "Claude Desktop app is not running."
            )
            return (cached5hReset, cachedWeeklyReset)
        }

        let axApp = AXUIElementCreateApplication(claudeApp.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
        var winArray = windows as? [AXUIElement] ?? []

        if winArray.isEmpty {
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &children) == .success,
               let chArr = children as? [AXUIElement] {
                winArray = chArr
            }
        }

        func findUsageButton(elem: AXUIElement, depth: Int = 0) -> AXUIElement? {
            if depth > 30 { return nil }
            var desc: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc)
            var title: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
            var val: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val)
            var help: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXHelpAttribute as CFString, &help)

            let s = [desc, title, val, help].compactMap({ $0 as? String }).joined(separator: " ").lowercased()
            if s.contains("usage:") || s.contains("plan usage") || (s.contains("usage") && s.contains("plan")) || (s.contains("5-hour") && s.contains("limit")) {
                return elem
            }

            var ch: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &ch) == .success, let childArray = ch as? [AXUIElement] {
                for c in childArray {
                    if let f = findUsageButton(elem: c, depth: depth + 1) { return f }
                }
            }
            return nil
        }

        var targetWin: AXUIElement? = nil
        var targetBtn: AXUIElement? = nil
        for w in winArray {
            if let btn = findUsageButton(elem: w) {
                targetWin = w
                targetBtn = btn
                break
            }
        }

        let mainWin = targetWin ?? winArray.first

        var strings: [String] = []
        func collectStrings(elem: AXUIElement, depth: Int = 0) {
            if depth > 35 { return }
            var val: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val)
            var title: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
            var desc: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc)
            var help: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXHelpAttribute as CFString, &help)

            for s in [val, title, desc, help].compactMap({ $0 as? String }).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
                strings.append(s)
            }

            var ch: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &ch) == .success, let childArray = ch as? [AXUIElement] {
                for c in childArray { collectStrings(elem: c, depth: depth + 1) }
            }
        }

        if let mw = mainWin {
            collectStrings(elem: mw)
        }

        let prevFrontmost = NSWorkspace.shared.frontmostApplication
        var popoverOpened = false

        if let usageBtn = targetBtn {
            // Bounded interaction: Open usage popover
            let pressResult = AXUIElementPerformAction(usageBtn, kAXPressAction as CFString)
            if pressResult == .success {
                popoverOpened = true
                Thread.sleep(forTimeInterval: 0.35)

                var afterWins: AnyObject?
                AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &afterWins)
                let afterWinArray = (afterWins as? [AXUIElement]) ?? (mainWin != nil ? [mainWin!] : [])
                for w in afterWinArray {
                    collectStrings(elem: w)
                }

                // Close popover immediately
                _ = AXUIElementPerformAction(usageBtn, kAXPressAction as CFString)

                // Restore prior focused application
                if let prev = prevFrontmost, prev.processIdentifier != claudeApp.processIdentifier {
                    prev.activate(options: [])
                }
            }
        }

        let now = Date()
        var raw5h: String? = nil
        var rawWeekly: String? = nil
        var candidateQuotas: [String] = []

        for i in 0..<strings.count {
            let s = strings[i]
            let lower = s.lowercased()

            // Safe quota metadata collection (no user prompts/conversations)
            if lower.contains("usage") || lower.contains("limit") || lower.contains("reset") || lower.contains("5-hour") || lower.contains("weekly") || lower.contains("%") {
                if candidateQuotas.count < 30 {
                    candidateQuotas.append(s)
                }
            }

            if lower.contains("5-hour limit") || lower.contains("5-hour") || lower.contains("current session") {
                for j in max(0, i-2)..<min(strings.count, i+6) {
                    if strings[j].lowercased().contains("reset") {
                        raw5h = strings[j]
                        if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: strings[j], observedAt: now, now: now, source: "claude_native_menu_ax") {
                            cached5hReset = obs
                        }
                        break
                    }
                }
            }

            if lower.contains("weekly limit") || lower.contains("weekly") || lower.contains("all models") {
                for j in max(0, i-2)..<min(strings.count, i+6) {
                    if strings[j].lowercased().contains("reset") {
                        rawWeekly = strings[j]
                        if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: strings[j], observedAt: now, now: now, source: "claude_native_menu_ax") {
                            cachedWeeklyReset = obs
                        }
                        break
                    }
                }
            }
        }

        // Fallback: standalone reset string parsing if sections were separated
        if raw5h == nil || rawWeekly == nil {
            for s in strings {
                let lower = s.lowercased()
                if lower.contains("reset") {
                    if let parsed = ClaudeLocalQuotaConnector.parseRelativeResetDurationDetails(from: s) {
                        if parsed.seconds <= 8 * 3600 && raw5h == nil {
                            raw5h = s
                            if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: s, observedAt: now, now: now, source: "claude_native_menu_ax") {
                                cached5hReset = obs
                            }
                        } else if parsed.seconds > 8 * 3600 && rawWeekly == nil {
                            rawWeekly = s
                            if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: s, observedAt: now, now: now, source: "claude_native_menu_ax") {
                                cachedWeeklyReset = obs
                            }
                        }
                    }
                }
            }
        }

        lastRefreshAttempt = now
        lastDebugInfo = ClaudeResetDebugInfo(
            agentSignalBarAXTrusted: isTrusted,
            claudeRunning: true,
            usageControlFound: targetBtn != nil,
            popoverOpened: popoverOpened,
            fiveHourRawReset: raw5h ?? cached5hReset?.relativeResetText,
            weeklyRawReset: rawWeekly ?? cachedWeeklyReset?.relativeResetText,
            fiveHourParsedReset: cached5hReset?.formattedResetText,
            weeklyParsedReset: cachedWeeklyReset?.formattedResetText,
            lastError: nil,
            windowsCount: winArray.count,
            scannedStringsCount: strings.count,
            candidateQuotaStrings: candidateQuotas
        )

        return (cached5hReset, cachedWeeklyReset)
    }

    public func getDebugInfo() -> ClaudeResetDebugInfo {
        lock.lock()
        defer { lock.unlock() }

        if let existing = lastDebugInfo {
            return existing
        }

        let isTrusted = AXIsProcessTrusted()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        let allApps = NSWorkspace.shared.runningApplications
        let app = apps.first ?? allApps.first(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName == "Claude" })

        return ClaudeResetDebugInfo(
            agentSignalBarAXTrusted: isTrusted,
            claudeRunning: app != nil,
            usageControlFound: false,
            popoverOpened: false,
            fiveHourRawReset: cached5hReset?.relativeResetText,
            weeklyRawReset: cachedWeeklyReset?.relativeResetText,
            fiveHourParsedReset: cached5hReset?.formattedResetText,
            weeklyParsedReset: cachedWeeklyReset?.formattedResetText,
            lastError: isTrusted ? nil : "AgentSignalBar lacks macOS Accessibility permission (TCC)."
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

        // Validate expiration: If reset deadline passed, invalidate expired observation
        if let s = cached5hReset {
            if now >= s.derivedAbsoluteReset {
                cached5hReset = nil
            } else {
                let relativeFormatted = ClaudeLocalQuotaConnector.formatClaudeResetDateTime(date: s.derivedAbsoluteReset, now: now, isApproximate: s.isApproximate)
                sText = "resets \(relativeFormatted)"
            }
        }
        if let w = cachedWeeklyReset {
            if now >= w.derivedAbsoluteReset {
                cachedWeeklyReset = nil
            } else {
                let relativeFormatted = ClaudeLocalQuotaConnector.formatClaudeResetDateTime(date: w.derivedAbsoluteReset, now: now, isApproximate: w.isApproximate)
                wText = "resets \(relativeFormatted)"
            }
        }

        return (sText, wText)
    }
}
