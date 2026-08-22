import AppKit
import AgentSignalBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Starting AgentSignalBar background service...")
        HTTPServer.shared.start()
        AutoMonitor.shared.start()
        TelegramBridge.shared.setup()
        MenuBarManager.shared.setup()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
