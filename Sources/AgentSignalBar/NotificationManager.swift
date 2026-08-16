import Foundation
import AppKit
import UserNotifications

public final class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    public var soundEnabled: Bool = true
    private var currentSound: NSSound?
    private var lastNotifiedStatus: [AgentID: AgentStatus] = [:]
    private var lastSoundTime: [AgentID: Date] = [:]
    private let soundCooldownSeconds: TimeInterval = 3.0

    private override init() {
        super.init()
        setupNotifications()
    }

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ macOS Banner Notification Permission granted!")
            } else if let error = error {
                print("⚠️ Notification Permission error: \(error)")
            }
        }
    }


    // Foreground notification display delegate (Guarantees pop-ups even when app is active!)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    public func toggleSound() -> Bool {
        soundEnabled.toggle()
        return soundEnabled
    }

    public func notify(agent: AgentID, oldStatus: AgentStatus, newStatus: AgentStatus, detail: String? = nil) {
        lastNotifiedStatus[agent] = newStatus

        guard newStatus == .done || newStatus == .blocked else { return }

        let title: String
        let defaultSoundName: String

        if newStatus == .blocked {
            title = "🔴 Attention Required: \(agent.displayName)"
            defaultSoundName = ConfigManager.shared.config.attentionSoundName ?? "Basso"
        } else {
            title = "🟢 Task Completed: \(agent.displayName)"
            defaultSoundName = ConfigManager.shared.config.doneSoundName ?? "Glass"
        }

        let body = detail ?? "\(agent.displayName) status updated to \(newStatus.rawValue)"

        // Dispatch Banner Notification if enabled
        let isBannerEnabled = ConfigManager.shared.config.notificationsEnabled ?? true
        if isBannerEnabled && Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound.default

            let request = UNNotificationRequest(
                identifier: "AgentSignal-\(agent.rawValue)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Failed to dispatch UNUserNotification: \(error)")
                }
            }
        }


            // 100% Guaranteed macOS System Notification via Process /usr/bin/osascript
            DispatchQueue.global(qos: .userInitiated).async {
                let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
                let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                try? task.run()
            }

        // Audio Alert with 3.0s Anti-Beeping Cooldown Protection
        let now = Date()
        let lastTime = lastSoundTime[agent] ?? Date.distantPast
        if soundEnabled && defaultSoundName != "Mute (No Sound)" && now.timeIntervalSince(lastTime) >= soundCooldownSeconds {
            lastSoundTime[agent] = now
            playSound(named: defaultSoundName)
        }
    }


    public func playSound(named soundName: String) {
        guard soundName != "Mute (No Sound)" else { return }
        stopCurrentSound()
        if let sound = NSSound(named: soundName) {
            currentSound = sound
            sound.play()
        }
    }

    public func stopCurrentSound() {
        currentSound?.stop()
        currentSound = nil
    }
}
