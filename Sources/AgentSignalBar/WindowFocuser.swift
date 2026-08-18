import Foundation
import AppKit

public struct WindowFocuser {
    public static func focusAgent(_ agent: AgentID, targetURL: String? = nil, sessionId: String? = nil, tabId: Int? = nil) {
        if agent == .chatgpt, let tid = tabId {
            HTTPServer.shared.requestTabFocus(tabId: tid)
            focusAppOnly("com.google.Chrome")
            return
        }
        switch agent {
        case .chatgpt:
            focusChromeChatGPT(targetURL: targetURL)
        case .codex:
            focusByBundleIdentifier("com.openai.codex", fallbackNames: ["ChatGPT", "Codex"])
        case .claude:
            focusByBundleIdentifier("com.anthropic.claudefordesktop", fallbackNames: ["Claude"])
        case .antigravity:
            focusByBundleIdentifier("com.google.antigravity", fallbackNames: ["Antigravity"])
        case .copilot:
            focusByBundleIdentifier("com.github.githubapp", fallbackNames: ["GitHub Copilot", "github", "Visual Studio Code", "Code"])
        }
    }

    public static func focusURL(_ urlString: String) {
        if urlString.contains("chatgpt.com") || urlString.contains("chat.openai.com") {
            focusChromeChatGPT(targetURL: urlString)
        } else {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public static func focusAppOnly(_ bundleID: String) {
        let workspace = NSWorkspace.shared
        if let targetApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            targetApp.activate(options: [.activateIgnoringOtherApps])
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

    public static func focusChromeChatGPT(targetURL: String? = nil) {
        let cleanTarget = targetURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var convId = ""
        if let cRange = cleanTarget.range(of: "/c/") {
            let afterC = String(cleanTarget[cRange.upperBound...])
            convId = afterC.components(separatedBy: "?").first?.components(separatedBy: "/").first ?? ""
        }

        let scriptSource = """
        tell application "Google Chrome"
            activate
            if (count of windows) > 0 then
                set targetURL to "\(cleanTarget)"
                set convId to "\(convId)"

                -- Strategy 1: Match by Conversation ID
                if convId is not "" then
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            if (URL of t) contains ("/c/" & convId) then
                                set active tab index of w to tabIndex
                                set index of w to 1
                                return true
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end if

                -- Strategy 2: Match by full URL substring
                if targetURL is not "" then
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            set tURL to URL of t
                            if (tURL is targetURL) or (tURL contains targetURL) or (targetURL contains tURL) then
                                set active tab index of w to tabIndex
                                set index of w to 1
                                return true
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end if

                -- Strategy 3: Fallback to any ChatGPT tab
                repeat with w in windows
                    set tabIndex to 1
                    repeat with t in tabs of w
                        set tURL to URL of t
                        if (tURL contains "chatgpt.com") or (tURL contains "chat.openai.com") then
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
            if !cleanTarget.isEmpty, let url = URL(string: cleanTarget) {
                NSWorkspace.shared.open(url)
            } else {
                focusByBundleIdentifier("com.google.Chrome", fallbackNames: ["Google Chrome"])
            }
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: source) {
            let res = scriptObject.executeAndReturnError(&error)
            if error != nil {
                return false
            }
            return res.booleanValue
        }
        return false
    }
}
