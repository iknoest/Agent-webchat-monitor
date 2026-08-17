import Foundation
import Cocoa
import ApplicationServices

public struct ClaudeResetObservation: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let relativeResetText: String
    public let relativeDurationSeconds: TimeInterval
    public let derivedAbsoluteReset: Date
    public let formattedResetText: String
    public let source: String
    public let authority: String

    public init(
        observedAt: Date,
        relativeResetText: String,
        relativeDurationSeconds: TimeInterval,
        derivedAbsoluteReset: Date,
        formattedResetText: String,
        source: String = "claude_native_ui_ax",
        authority: String = "ui_derived_first_party"
    ) {
        self.observedAt = observedAt
        self.relativeResetText = relativeResetText
        self.relativeDurationSeconds = relativeDurationSeconds
        self.derivedAbsoluteReset = derivedAbsoluteReset
        self.formattedResetText = formattedResetText
        self.source = source
        self.authority = authority
    }
}

public final class ClaudeLocalQuotaConnector: @unchecked Sendable {
    public static let shared = ClaudeLocalQuotaConnector()

    private var cached5hReset: ClaudeResetObservation? = nil
    private var cachedWeeklyReset: ClaudeResetObservation? = nil
    private let lock = NSLock()

    private init() {}

    // Parse relative duration from strings like "resets 3h", "resets 42m", "17% · resets 3h", "resets in 1h 15m"
    public static func parseRelativeResetDuration(from text: String) -> TimeInterval? {
        let lower = text.lowercased()
        guard lower.contains("reset") else { return nil }

        var totalSeconds: TimeInterval = 0
        var matchedAny = false

        // Days (e.g. "2d" or "2 d")
        if let match = lower.range(of: "(\\d+)\\s*d", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "d", with: "").trimmingCharacters(in: .whitespaces)
            if let days = Double(numStr) {
                totalSeconds += days * 86400
                matchedAny = true
            }
        }

        // Hours (e.g. "3h" or "3 h")
        if let match = lower.range(of: "(\\d+)\\s*h", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "h", with: "").trimmingCharacters(in: .whitespaces)
            if let hours = Double(numStr) {
                totalSeconds += hours * 3600
                matchedAny = true
            }
        }

        // Minutes (e.g. "42m" or "42 m", but avoid matching "ms")
        if let match = lower.range(of: "(\\d+)\\s*m(?!s)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            if let mins = Double(numStr) {
                totalSeconds += mins * 60
                matchedAny = true
            }
        }

        return (matchedAny && totalSeconds > 0) ? totalSeconds : nil
    }

    // Derive absolute reset date and format according to AgentSignalBar standardized 24-hour style
    public static func deriveResetObservation(
        relativeText: String,
        observedAt: Date = Date(),
        now: Date = Date()
    ) -> ClaudeResetObservation? {
        guard let duration = parseRelativeResetDuration(from: relativeText) else {
            return nil
        }
        let derivedDate = observedAt.addingTimeInterval(duration)
        let formattedDate = AntigravityLocalQuotaConnector.formatResetDateTime(date: derivedDate, now: now)
        let formattedReset = "resets \(formattedDate)"

        return ClaudeResetObservation(
            observedAt: observedAt,
            relativeResetText: relativeText,
            relativeDurationSeconds: duration,
            derivedAbsoluteReset: derivedDate,
            formattedResetText: formattedReset
        )
    }

    // Non-intrusive Accessibility UI Inspector: Inspects Claude Desktop UI elements for reset strings
    public func queryClaudeNativeAXReset() -> (sessionReset: ClaudeResetObservation?, weeklyReset: ClaudeResetObservation?) {
        lock.lock()
        defer { lock.unlock() }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        guard let app = apps.first else {
            return (cached5hReset, cachedWeeklyReset)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var extractedStrings: [String] = []

        func extractResetStrings(from elem: AXUIElement, depth: Int = 0) {
            if depth > 10 { return }
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val) == .success, let valStr = val as? String {
                if valStr.lowercased().contains("reset") && (valStr.contains("h") || valStr.contains("m") || valStr.contains("d")) {
                    extractedStrings.append(valStr)
                }
            }
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title) == .success, let titleStr = title as? String {
                if titleStr.lowercased().contains("reset") && (titleStr.contains("h") || titleStr.contains("m") || titleStr.contains("d")) {
                    extractedStrings.append(titleStr)
                }
            }
            var desc: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc) == .success, let descStr = desc as? String {
                if descStr.lowercased().contains("reset") && (descStr.contains("h") || descStr.contains("m") || descStr.contains("d")) {
                    extractedStrings.append(descStr)
                }
            }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &children) == .success, let childArray = children as? [AXUIElement] {
                for c in childArray {
                    extractResetStrings(from: c, depth: depth + 1)
                }
            }
        }

        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success, let wins = windows as? [AXUIElement] {
            for w in wins {
                extractResetStrings(from: w)
            }
        }

        let now = Date()
        for rawStr in extractedStrings {
            let lower = rawStr.lowercased()
            if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: rawStr, observedAt: now, now: now) {
                if lower.contains("5-hour") || lower.contains("5h") || lower.contains("hour") {
                    cached5hReset = obs
                } else if lower.contains("week") {
                    cachedWeeklyReset = obs
                } else if cached5hReset == nil {
                    cached5hReset = obs
                }
            }
        }

        return (cached5hReset, cachedWeeklyReset)
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
            let relativeFormatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: s.derivedAbsoluteReset, now: now)
            sText = "resets \(relativeFormatted)"
        }
        if let w = cachedWeeklyReset {
            let relativeFormatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: w.derivedAbsoluteReset, now: now)
            wText = "resets \(relativeFormatted)"
        }

        return (sText, wText)
    }
}
