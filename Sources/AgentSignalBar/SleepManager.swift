import Foundation
import IOKit.pwr_mgt
import IOKit.ps

public enum AntiSleepMode: String, Codable, CaseIterable {
    case smartAuto = "smartAuto"       // Smart Auto driven by real agent lifecycle states across all monitored providers
    case alwaysOn = "alwaysOn"         // Always prevent sleep indefinitely
    case timer1h = "timer1h"           // Prevent sleep for 1 hour
    case timer3h = "timer3h"           // Prevent sleep for 3 hours
    case disabled = "disabled"         // Anti-sleep disabled

    public var displayName: String {
        switch self {
        case .smartAuto: return "Smart Auto (Monitored Agents)"
        case .alwaysOn: return "Always Awake (Indefinite)"
        case .timer1h: return "Awake for 1 Hour"
        case .timer3h: return "Awake for 3 Hours"
        case .disabled: return "Disabled (Normal macOS Sleep)"
        }
    }
}

public struct PowerStateInfo: Codable, Sendable {
    public let isACPower: Bool
    public let batteryPercent: Int?
    public let isCharging: Bool
    public let isBatterySafe: Bool
}

public final class SleepManager: @unchecked Sendable {
    public static let shared = SleepManager()

    public static let supportedSmartAutoProviders: Set<AgentID> = Set(AgentID.allCases)
    public static var trustedProviders: Set<AgentID> {
        return supportedSmartAutoProviders
    }
    public static let disableSleepMarkerPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/.config/AgentSignalBar/disablesleep_active"
    }()

    private var assertionID: IOPMAssertionID = 0
    public private(set) var isAssertionActive: Bool = false
    public private(set) var isDisableSleepActive: Bool = false
    public private(set) var currentReason: String? = nil
    private var caffeinateProcess: Process?
    private var timer: Timer?
    private var timerExpiryDate: Date?

    public var isClosedLidModeEnabled: Bool {
        get {
            if let explicit = ConfigManager.shared.config.isClosedLidEnabled {
                return explicit
            }
            let priv = SleepManager.checkPrivilegeStatus()
            return priv.hasPrivilege
        }
        set {
            ConfigManager.shared.setClosedLidEnabled(newValue)
            updateSleepAssertionState()
        }
    }

    public var mode: AntiSleepMode = .smartAuto {
        didSet {
            updateSleepAssertionState()
        }
    }

    private init() {
        // 1. Audit and clean up orphaned caffeinate processes from previous runs
        SleepManager.cleanupStaleCaffeinateProcesses()

        // 2. Audit and restore normal sleep if prior abnormal termination left disablesleep active
        SleepManager.cleanupStaleDisableSleepState()

        let savedModeStr = ConfigManager.shared.config.antiSleepMode ?? "smartAuto"
        self.mode = AntiSleepMode(rawValue: savedModeStr) ?? .smartAuto

        // Observe Agent status changes
        AgentStore.shared.addObserver(id: "SleepManager") { [weak self] _, _, _, _ in
            self?.updateSleepAssertionState()
        }
    }

    public func evaluateSmartAutoRequirement() -> (shouldKeepAwake: Bool, reason: String) {
        let monitored = SleepManager.supportedSmartAutoProviders.filter { ConfigManager.shared.isAgentMonitored($0) }

        // Quota exhaustion is provider availability: providers with exhausted quota CANNOT execute
        // and must NOT independently keep Smart Auto awake or masquerade as a user-action gate.
        let availableMonitored = monitored.filter { AgentStore.shared.getAvailability(for: $0) != .quotaExhausted }

        // 1. Check child sessions of available monitored providers
        let allSessions = AgentStore.shared.getAllSessions().filter { availableMonitored.contains($0.provider) }
        let workingSessions = allSessions.filter { $0.status == .working }
        let blockedSessions = allSessions.filter { $0.status == .blocked }

        // 2. Check parent states of available monitored providers
        let allStates = AgentStore.shared.getAllStates()
        let monitoredParentStates = allStates.filter { availableMonitored.contains($0.key) }
        let workingParents = monitoredParentStates.values.filter { $0.status == .working }
        let blockedParents = monitoredParentStates.values.filter { $0.status == .blocked }

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

        return (false, "Smart Auto: All monitored agents idle/done/off")
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
            if isClosedLidModeEnabled {
                enableClosedLidPrevention(reason: reason)
            } else {
                disableClosedLidPrevention()
            }
        } else {
            disableSleepPrevention()
            disableClosedLidPrevention()
        }
    }

    public var statusDescription: String {
        var prefix = isAssertionActive ? "ACTIVE: \(currentReason ?? "Keep awake held")" : "IDLE: \(currentReason ?? "Released sleep assertion")"
        if isDisableSleepActive {
            prefix += " [Closed-Lid pmset Active]"
        }
        return prefix
    }

    public func getDebugInfo() -> [String: Any] {
        let minBatt = ConfigManager.shared.config.minBatteryPercentForClosedLid ?? 20
        let power = SleepManager.getPowerState(minBatteryPercent: minBatt)
        let priv = SleepManager.checkPrivilegeStatus()

        return [
            "mode": mode.rawValue,
            "modeDisplayName": mode.displayName,
            "isAssertionActive": isAssertionActive,
            "isClosedLidEnabled": isClosedLidModeEnabled,
            "isDisableSleepActive": isDisableSleepActive,
            "hasClosedLidPrivilege": priv.hasPrivilege,
            "privilegeDetail": priv.detail,
            "powerState": [
                "isACPower": power.isACPower,
                "batteryPercent": power.batteryPercent as Any,
                "isCharging": power.isCharging,
                "isBatterySafe": power.isBatterySafe
            ],
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

    // MARK: - Battery & Power State Inspection
    public static func getPowerState(minBatteryPercent: Int = 20) -> PowerStateInfo {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        var isAC = false
        var batteryCapacity: Int? = nil
        var isCharging = false

        for s in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, s).takeUnretainedValue() as? [String: Any] {
                let state = desc[kIOPSPowerSourceStateKey as String] as? String
                if state == (kIOPSACPowerValue as String) {
                    isAC = true
                }
                if let cap = desc[kIOPSCurrentCapacityKey as String] as? Int {
                    batteryCapacity = cap
                }
                if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                    isCharging = charging
                }
            }
        }

        let isSafe = isAC || ((batteryCapacity ?? 0) >= minBatteryPercent)
        return PowerStateInfo(isACPower: isAC, batteryPercent: batteryCapacity, isCharging: isCharging, isBatterySafe: isSafe)
    }

    // MARK: - Privilege & Sudo Validation
    public static func checkPrivilegeStatus() -> (hasPrivilege: Bool, detail: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", "/usr/bin/pmset"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = task.terminationStatus
            if code == 0 && (outStr.contains("NOPASSWD") || outStr.contains("disablesleep") || outStr.contains("ALL")) {
                return (true, "Passwordless sudo configured for pmset")
            } else if code == 0 {
                return (true, "Sudo validation succeeded")
            } else {
                return (false, "Sudo privilege not configured (requires sudoers rule)")
            }
        } catch {
            return (false, "Failed to run sudo check: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public static func executePmsetDisableSleep(enable: Bool) -> (success: Bool, exitCode: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/bin/pmset", "disablesleep", enable ? "1" : "0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = task.terminationStatus
            return (code == 0, code, outStr)
        } catch {
            return (false, -1, error.localizedDescription)
        }
    }

    // MARK: - Stale State Recovery on Launch
    public static func cleanupStaleDisableSleepState() {
        let fm = FileManager.default
        let marker = disableSleepMarkerPath

        var isStale = false
        if fm.fileExists(atPath: marker) {
            isStale = true
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "live"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let outStr = String(data: data, encoding: .utf8), outStr.contains("SleepDisabled") && outStr.contains("1") {
                isStale = true
            }
        }

        if isStale {
            print("🧹 Detected stale or active SleepDisabled state from prior run. Restoring normal sleep...")
            let res = executePmsetDisableSleep(enable: false)
            if res.success {
                try? fm.removeItem(atPath: marker)
                print("✅ Successfully restored normal sleep (pmset disablesleep 0) on startup")
            } else {
                print("⚠️ Could not restore pmset disablesleep 0: \(res.output)")
            }
        }
    }

    public func enableClosedLidPrevention(reason: String) {
        let minBatt = ConfigManager.shared.config.minBatteryPercentForClosedLid ?? 20
        let powerState = SleepManager.getPowerState(minBatteryPercent: minBatt)

        if !powerState.isBatterySafe {
            print("⚠️ Closed-lid mode suppressed: battery low (\(powerState.batteryPercent ?? 0)%) on battery power")
            if isDisableSleepActive {
                disableClosedLidPrevention()
            }
            return
        }

        if !isDisableSleepActive {
            let res = SleepManager.executePmsetDisableSleep(enable: true)
            if res.success {
                isDisableSleepActive = true
                let markerContent = "pid:\(ProcessInfo.processInfo.processIdentifier)\ntime:\(Date().timeIntervalSince1970)\nreason:\(reason)\n"
                try? markerContent.write(toFile: SleepManager.disableSleepMarkerPath, atomically: true, encoding: .utf8)
                print("🛡️ Enabled macOS Closed-Lid keep-awake (pmset disablesleep 1): \(reason)")
            } else {
                print("⚠️ Failed to enable pmset disablesleep 1: \(res.output)")
            }
        }
    }

    public func disableClosedLidPrevention() {
        if isDisableSleepActive || FileManager.default.fileExists(atPath: SleepManager.disableSleepMarkerPath) {
            let res = SleepManager.executePmsetDisableSleep(enable: false)
            try? FileManager.default.removeItem(atPath: SleepManager.disableSleepMarkerPath)
            isDisableSleepActive = false
            if res.success {
                print("🛡️ Restored macOS Normal sleep (pmset disablesleep 0)")
            } else {
                print("⚠️ Failed to restore pmset disablesleep 0: \(res.output)")
            }
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

    public func getLiveIOPMAssertionName() -> String? {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let dict = assertions?.takeRetainedValue() as? [pid_t: [[String: Any]]] else {
            return nil
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let list = dict[myPID] else { return nil }
        for item in list {
            if let aid = item["AssertionId"] as? IOPMAssertionID, aid == assertionID,
               let name = item["AssertName"] as? String {
                return name
            }
        }
        return nil
    }

    private func enableSleepPrevention(reason: String) {
        let reasonChanged = (isAssertionActive && currentReason != reason)
        currentReason = reason

        if reasonChanged {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isAssertionActive = false
        }

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
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
            caffeinateProcess = nil
            print("💤 Terminated caffeinate process")
        }
    }

    deinit {
        disableSleepPrevention()
        disableClosedLidPrevention()
    }
}
