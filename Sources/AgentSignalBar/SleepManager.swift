import Foundation
import IOKit.pwr_mgt

public enum AntiSleepMode: String, Codable, CaseIterable {
    case smartAuto = "smartAuto"       // Auto-prevent sleep ONLY while any agent is working
    case alwaysOn = "alwaysOn"         // Always prevent sleep indefinitely
    case timer1h = "timer1h"           // Prevent sleep for 1 hour
    case timer3h = "timer3h"           // Prevent sleep for 3 hours
    case disabled = "disabled"         // Anti-sleep disabled

    public var displayName: String {
        switch self {
        case .smartAuto: return "Smart Auto (Awake while agents work)"
        case .alwaysOn: return "Always Awake (Indefinite)"
        case .timer1h: return "Awake for 1 Hour"
        case .timer3h: return "Awake for 3 Hours"
        case .disabled: return "Disabled (Normal macOS Sleep)"
        }
    }
}

public final class SleepManager: @unchecked Sendable {
    public static let shared = SleepManager()

    private var assertionID: IOPMAssertionID = 0
    private var isAssertionActive: Bool = false
    private var caffeinateProcess: Process?
    private var timer: Timer?
    private var timerExpiryDate: Date?

    public var mode: AntiSleepMode = .smartAuto {
        didSet {
            updateSleepAssertionState()
        }
    }

    private init() {
        // Observe Agent status changes
        AgentStore.shared.onStateChanged = { [weak self] _, _, _, _ in
            self?.updateSleepAssertionState()
        }
    }

    public func updateSleepAssertionState() {
        let anyAgentWorking = AgentStore.shared.getAllStates().values.contains(where: { $0.status == .working })

        var shouldKeepAwake = false

        switch mode {
        case .smartAuto:
            shouldKeepAwake = anyAgentWorking
        case .alwaysOn:
            shouldKeepAwake = true
        case .timer1h, .timer3h:
            if let expiry = timerExpiryDate, Date() < expiry {
                shouldKeepAwake = true
            } else {
                mode = .smartAuto
                shouldKeepAwake = anyAgentWorking
            }
        case .disabled:
            shouldKeepAwake = false
        }

        if shouldKeepAwake {
            enableSleepPrevention(reason: anyAgentWorking ? "AI Agent active & working" : "Anti-sleep mode active")
        } else {
            disableSleepPrevention()
        }
    }

    public func setTimerMode(hours: Int) {
        let seconds = Double(hours * 3600)
        timerExpiryDate = Date().addingTimeInterval(seconds)
        mode = hours == 1 ? .timer1h : .timer3h

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            print("⏱️ Anti-sleep timer expired!")
            self?.mode = .smartAuto
        }
    }

    private func enableSleepPrevention(reason: String) {
        guard !isAssertionActive else { return }

        // 1. Native IOKit IOPMAssertion
        let reasonString = reason as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonString,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isAssertionActive = true
            print("☕ Enabled macOS Anti-Sleep assertion (ID: \(assertionID)): \(reason)")
        }

        // 2. Fallback caffeinate CLI process (prevents system & display sleep even with lid closed in clamshell)
        if caffeinateProcess == nil {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            proc.arguments = ["-d", "-i", "-s", "-u"]
            try? proc.run()
            caffeinateProcess = proc
            print("☕ Launched caffeinate anti-sleep process (-d -i -s -u)")
        }
    }

    private func disableSleepPrevention() {
        guard isAssertionActive || caffeinateProcess != nil else { return }

        if isAssertionActive {
            IOPMAssertionRelease(assertionID)
            isAssertionActive = false
            assertionID = 0
            print("💤 Released macOS Anti-Sleep assertion")
        }

        if let proc = caffeinateProcess {
            proc.terminate()
            caffeinateProcess = nil
            print("💤 Terminated caffeinate process")
        }
    }

    deinit {
        disableSleepPrevention()
    }
}
