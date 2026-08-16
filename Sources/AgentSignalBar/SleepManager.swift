import Foundation
import IOKit.pwr_mgt

public enum AntiSleepMode: String, Codable, CaseIterable {
    case smartAuto = "smartAuto"       // Smart Auto driven by trusted real agent lifecycle states (ChatGPT, Claude, AGY)
    case alwaysOn = "alwaysOn"         // Always prevent sleep indefinitely
    case timer1h = "timer1h"           // Prevent sleep for 1 hour
    case timer3h = "timer3h"           // Prevent sleep for 3 hours
    case disabled = "disabled"         // Anti-sleep disabled

    public var displayName: String {
        switch self {
        case .smartAuto: return "Smart Auto (ChatGPT / Claude / AGY Active)"
        case .alwaysOn: return "Always Awake (Indefinite)"
        case .timer1h: return "Awake for 1 Hour"
        case .timer3h: return "Awake for 3 Hours"
        case .disabled: return "Disabled (Normal macOS Sleep)"
        }
    }
}

public final class SleepManager: @unchecked Sendable {
    public static let shared = SleepManager()

    public static let trustedProviders: Set<AgentID> = [.chatgpt, .claude, .antigravity]

    private var assertionID: IOPMAssertionID = 0
    public private(set) var isAssertionActive: Bool = false
    public private(set) var currentReason: String? = nil
    private var caffeinateProcess: Process?
    private var timer: Timer?
    private var timerExpiryDate: Date?

    public var mode: AntiSleepMode = .smartAuto {
        didSet {
            updateSleepAssertionState()
        }
    }

    private init() {
        // Audit and clean up orphaned caffeinate processes from previous runs on startup
        SleepManager.cleanupStaleCaffeinateProcesses()

        let savedModeStr = ConfigManager.shared.config.antiSleepMode ?? "smartAuto"
        self.mode = AntiSleepMode(rawValue: savedModeStr) ?? .smartAuto

        // Observe Agent status changes
        AgentStore.shared.addObserver(id: "SleepManager") { [weak self] _, _, _, _ in
            self?.updateSleepAssertionState()
        }
    }

    public func evaluateSmartAutoRequirement() -> (shouldKeepAwake: Bool, reason: String) {
        let trusted = SleepManager.trustedProviders

        // Quota exhaustion is provider availability: providers with exhausted quota CANNOT execute
        // and must NOT independently keep Smart Auto awake or masquerade as a user-action gate.
        let availableTrusted = trusted.filter { AgentStore.shared.getAvailability(for: $0) == .available }

        // 1. Check child sessions of available trusted providers
        let allSessions = AgentStore.shared.getAllSessions().filter { availableTrusted.contains($0.provider) }
        let workingSessions = allSessions.filter { $0.status == .working }
        let blockedSessions = allSessions.filter { $0.status == .blocked }

        // 2. Check parent states of available trusted providers
        let allStates = AgentStore.shared.getAllStates()
        let trustedParentStates = allStates.filter { availableTrusted.contains($0.key) }
        let workingParents = trustedParentStates.values.filter { $0.status == .working }
        let blockedParents = trustedParentStates.values.filter { $0.status == .blocked }

        if !blockedSessions.isEmpty || !blockedParents.isEmpty {
            let blockedNames = Set(blockedSessions.map { $0.provider.displayName } + blockedParents.map { $0.id.displayName })
            let agentList = Array(blockedNames).sorted().joined(separator: ", ")
            return (true, "Smart Auto: Agent needs attention (\(agentList))")
        }

        if !workingSessions.isEmpty || !workingParents.isEmpty {
            let workingNames = Set(workingSessions.map { $0.provider.displayName } + workingParents.map { $0.id.displayName })
            let agentList = Array(workingNames).sorted().joined(separator: ", ")
            return (true, "Smart Auto: Agent working (\(agentList))")
        }

        return (false, "Smart Auto: All trusted agents idle/done/off")
    }

    public func updateSleepAssertionState() {
        var shouldKeepAwake = false
        var reason = ""

        switch mode {
        case .smartAuto:
            let eval = evaluateSmartAutoRequirement()
            shouldKeepAwake = eval.shouldKeepAwake
            reason = eval.reason
        case .alwaysOn:
            shouldKeepAwake = true
            reason = "Always Awake (Indefinite)"
        case .timer1h, .timer3h:
            if let expiry = timerExpiryDate, Date() < expiry {
                shouldKeepAwake = true
                let remainingMins = max(1, Int(ceil(expiry.timeIntervalSinceNow / 60)))
                reason = "Anti-sleep timer active (\(remainingMins)m remaining)"
            } else {
                mode = .disabled
                shouldKeepAwake = false
                reason = "Timer expired"
            }
        case .disabled:
            shouldKeepAwake = false
            reason = "Disabled"
        }

        if shouldKeepAwake {
            enableSleepPrevention(reason: reason)
        } else {
            disableSleepPrevention()
        }
    }

    public var statusDescription: String {
        if isAssertionActive {
            return "ACTIVE: \(currentReason ?? "Keep awake held")"
        } else {
            return "IDLE: \(currentReason ?? "Released sleep assertion")"
        }
    }

    public func getDebugInfo() -> [String: Any] {
        return [
            "mode": mode.rawValue,
            "modeDisplayName": mode.displayName,
            "isAssertionActive": isAssertionActive,
            "assertionID": assertionID,
            "reason": currentReason ?? "",
            "caffeinatePID": caffeinateProcess?.processIdentifier as Any,
            "trustedProviders": Array(SleepManager.trustedProviders.map { $0.rawValue }).sorted()
        ]
    }

    public func setTimerMode(hours: Int) {
        let seconds = Double(hours * 3600)
        timerExpiryDate = Date().addingTimeInterval(seconds)
        mode = hours == 1 ? .timer1h : .timer3h

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            print("⏱️ Anti-sleep timer expired!")
            self?.mode = .disabled
        }
    }

    @discardableResult
    public static func cleanupStaleCaffeinateProcesses(currentAppPID: pid_t = ProcessInfo.processInfo.processIdentifier, activeChildPID: pid_t? = nil) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,ppid,command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var terminatedPIDs: [pid_t] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("PID") else { continue }
            guard trimmed.contains("caffeinate") && trimmed.contains("-d") && trimmed.contains("-i") && trimmed.contains("-s") && trimmed.contains("-u") else { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }

            // Protect the current app process and any active child of current process
            if pid == currentAppPID { continue }
            if let child = activeChildPID, pid == child { continue }

            // Positively attribute: PPID is 1 (launchd orphan from dead parent process)
            if ppid == 1 {
                print("🧹 Cleaning up stale AgentSignalBar-owned caffeinate child PID \(pid) (PPID 1)")
                kill(pid, SIGTERM)
                usleep(50000) // 50ms pause
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
                terminatedPIDs.append(pid)
            }
        }

        return terminatedPIDs
    }

    private func enableSleepPrevention(reason: String) {
        currentReason = reason
        if !isAssertionActive {
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
        }

        if caffeinateProcess == nil || !(caffeinateProcess?.isRunning ?? false) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            let myPID = ProcessInfo.processInfo.processIdentifier
            proc.arguments = ["-d", "-i", "-s", "-u", "-w", "\(myPID)"]
            try? proc.run()
            caffeinateProcess = proc
            print("☕ Launched caffeinate anti-sleep process (-d -i -s -u -w \(myPID))")
        }
    }

    private func disableSleepPrevention() {
        currentReason = nil
        if isAssertionActive {
            IOPMAssertionRelease(assertionID)
            isAssertionActive = false
            assertionID = 0
            print("💤 Released macOS Anti-Sleep assertion")
        }

        if let proc = caffeinateProcess {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            caffeinateProcess = nil
            print("💤 Terminated caffeinate process")
        }
    }

    deinit {
        disableSleepPrevention()
    }
}
