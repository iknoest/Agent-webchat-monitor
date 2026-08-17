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
        source: String = "claude_native_menu_ax",
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

    public var isExpired: Bool {
        return Date() >= derivedAbsoluteReset
    }
}

public final class ClaudeLocalQuotaConnector: @unchecked Sendable {
    public static let shared = ClaudeLocalQuotaConnector()

    private var cached5hReset: ClaudeResetObservation? = nil
    private var cachedWeeklyReset: ClaudeResetObservation? = nil
    private var lastRefreshAttempt: Date = .distantPast
    private let lock = NSLock()

    private init() {}

    // Parse relative duration from strings like "resets 3h", "resets 42m", "17% · resets 3h", "Resets in 3 hr 36 min", "Resets in 1 hr 26 min"
    public static func parseRelativeResetDuration(from text: String) -> TimeInterval? {
        let lower = text.lowercased()
        guard lower.contains("reset") else { return nil }

        var totalSeconds: TimeInterval = 0
        var matchedAny = false

        // Days
        if let match = lower.range(of: "(\\d+)\\s*(?:d|day|days)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let days = Double(numStr) {
                totalSeconds += days * 86400
                matchedAny = true
            }
        }

        // Hours
        if let match = lower.range(of: "(\\d+)\\s*(?:h|hr|hrs|hour|hours)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let hours = Double(numStr) {
                totalSeconds += hours * 3600
                matchedAny = true
            }
        }

        // Minutes
        if let match = lower.range(of: "(\\d+)\\s*(?:m|min|mins|minute|minutes)(?!s)", options: .regularExpression) {
            let numStr = lower[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
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
        now: Date = Date(),
        source: String = "claude_native_menu_ax"
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
            formattedResetText: formattedReset,
            source: source,
            authority: "ui_derived_first_party"
        )
    }

    // Explicit Bounded Refresh: Inspects Claude Desktop UI for live 5-hour and Weekly reset strings
    @discardableResult
    public func refreshClaudeNativeAXReset() -> (sessionReset: ClaudeResetObservation?, weeklyReset: ClaudeResetObservation?) {
        lock.lock()
        defer { lock.unlock() }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        let allApps = NSWorkspace.shared.runningApplications
        guard let app = apps.first ?? allApps.first(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName == "Claude" }) else {
            return (cached5hReset, cachedWeeklyReset)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
        let winArray = windows as? [AXUIElement] ?? []

        func findUsageButton(elem: AXUIElement) -> AXUIElement? {
            var desc: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc)
            var title: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
            var val: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val)
            let s = [desc, title, val].compactMap({ $0 as? String }).joined(separator: " ")
            if s.contains("Usage:") || s.contains("Plan usage") || (s.contains("Usage") && s.contains("plan")) {
                return elem
            }
            var ch: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &ch) == .success, let childArray = ch as? [AXUIElement] {
                for c in childArray {
                    if let f = findUsageButton(elem: c) { return f }
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

        guard let mainWin = targetWin ?? winArray.first else {
            return (cached5hReset, cachedWeeklyReset)
        }

        var strings: [String] = []
        func collectStrings(elem: AXUIElement, depth: Int = 0) {
            if depth > 30 { return }
            var val: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val)
            var title: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
            var desc: AnyObject?
            AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc)
            for s in [val, title, desc].compactMap({ $0 as? String }).filter({ !$0.isEmpty }) {
                strings.append(s)
            }
            var ch: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &ch) == .success, let childArray = ch as? [AXUIElement] {
                for c in childArray { collectStrings(elem: c, depth: depth + 1) }
            }
        }

        collectStrings(elem: mainWin)

        let prevFrontmost = NSWorkspace.shared.frontmostApplication

        if let usageBtn = targetBtn {
            // Bounded interaction: Open usage popover
            _ = AXUIElementPerformAction(usageBtn, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.35)

            var afterWins: AnyObject?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &afterWins)
            for w in (afterWins as? [AXUIElement]) ?? [mainWin] {
                collectStrings(elem: w)
            }

            // Close popover immediately
            _ = AXUIElementPerformAction(usageBtn, kAXPressAction as CFString)

            // Restore prior focused application
            if let prev = prevFrontmost, prev.processIdentifier != app.processIdentifier {
                prev.activate(options: [])
            }
        }

        let now = Date()
        for i in 0..<strings.count {
            let s = strings[i]
            if s.contains("5-hour limit") || s.contains("5-hour") {
                for j in (i+1)..<min(strings.count, i+5) {
                    if strings[j].lowercased().contains("reset") {
                        if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: strings[j], observedAt: now, now: now, source: "claude_native_menu_ax") {
                            cached5hReset = obs
                            print("✅ [Claude AX] Captured 5h reset: \(obs.formattedResetText) from '\(strings[j])'")
                        }
                        break
                    }
                }
            }
            if s.contains("Weekly") {
                for j in (i+1)..<min(strings.count, i+5) {
                    if strings[j].lowercased().contains("reset") {
                        if let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: strings[j], observedAt: now, now: now, source: "claude_native_menu_ax") {
                            cachedWeeklyReset = obs
                            print("✅ [Claude AX] Captured Weekly reset: \(obs.formattedResetText) from '\(strings[j])'")
                        }
                        break
                    }
                }
            }
        }

        lastRefreshAttempt = now
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

        // Validate expiration: If reset deadline passed, invalidate expired observation
        if let s = cached5hReset {
            if now >= s.derivedAbsoluteReset {
                cached5hReset = nil
            } else {
                let relativeFormatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: s.derivedAbsoluteReset, now: now)
                sText = "resets \(relativeFormatted)"
            }
        }
        if let w = cachedWeeklyReset {
            if now >= w.derivedAbsoluteReset {
                cachedWeeklyReset = nil
            } else {
                let relativeFormatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: w.derivedAbsoluteReset, now: now)
                wText = "resets \(relativeFormatted)"
            }
        }

        return (sText, wText)
    }
}
