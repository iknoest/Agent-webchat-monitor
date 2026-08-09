import Foundation
import AppKit

public struct WindowFocuser {
    public static func focusAgent(_ agent: AgentID) {
        switch agent {
        case .chatgpt:
            focusChromeChatGPT()
        case .codex:
            focusByBundleIdentifier("com.openai.codex", fallbackNames: ["ChatGPT", "Codex"])
        case .claude:
            focusByBundleIdentifier("com.anthropic.claudefordesktop", fallbackNames: ["Claude"])
        case .antigravity:
            focusByBundleIdentifier("com.google.antigravity", fallbackNames: ["Antigravity"])
        }
    }

    private static func focusByBundleIdentifier(_ bundleID: String, fallbackNames: [String]) {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications

        // 1. Match exact bundle identifier
        if let targetApp = apps.first(where: { $0.bundleIdentifier == bundleID }) {
            targetApp.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // 2. Match localized name
        for name in fallbackNames {
            if let targetApp = apps.first(where: { $0.localizedName?.lowercased() == name.lowercased() }) {
                targetApp.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }

        // 3. AppleScript fallback by name
        if let firstName = fallbackNames.first {
            let script = "tell application \"\(firstName)\" to activate"
            runAppleScript(script)
        }
    }

    private static func focusChromeChatGPT() {
        let scriptSource = """
        tell application "Google Chrome"
            activate
            if (count of windows) > 0 then
                repeat with w in windows
                    set tabIndex to 1
                    repeat with t in tabs of w
                        if (URL of t contains "chatgpt.com") or (URL of t contains "chat.openai.com") then
                            set active tab index of w to tabIndex
                            set index of w to 1
                            return true
                        end if
                        set tabIndex to tabIndex + 1
                    end repeat
                end repeat
            end if
        end tell
        """

        if !runAppleScript(scriptSource) {
            focusByBundleIdentifier("com.google.Chrome", fallbackNames: ["Google Chrome"])
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: source) {
            scriptObject.executeAndReturnError(&error)
            if error != nil {
                return false
            }
            return true
        }
        return false
    }
}
