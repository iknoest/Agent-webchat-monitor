import Foundation
import AppKit
import ApplicationServices

func getAXAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if error == .success {
        return value
    }
    return nil
}

func getAXChildren(_ element: AXUIElement) -> [AXUIElement] {
    if let children = getAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        return children
    }
    return []
}

func dumpAllElements(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 12) {
    if depth > maxDepth { return }

    let role = getAXAttribute(element, kAXRoleAttribute) as? String ?? ""
    let subrole = getAXAttribute(element, kAXSubroleAttribute) as? String ?? ""
    let title = getAXAttribute(element, kAXTitleAttribute) as? String ?? ""
    let desc = getAXAttribute(element, kAXDescriptionAttribute) as? String ?? ""
    let value = getAXAttribute(element, kAXValueAttribute) as? String ?? ""
    let identifier = getAXAttribute(element, "AXIdentifier") as? String ?? ""
    let modal = getAXAttribute(element, "AXModal") as? Bool ?? false

    let indent = String(repeating: "  ", count: depth)
    print("\(indent)[\(depth)] role: \(role) | subrole: \(subrole) | title: \"\(title)\" | desc: \"\(desc)\" | val: \"\(value.prefix(50))\" | id: \"\(identifier)\" | modal: \(modal)")

    let children = getAXChildren(element)
    for child in children {
        dumpAllElements(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

let workspace = NSWorkspace.shared
guard let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.google.antigravity" || $0.localizedName?.lowercased() == "antigravity" }) else {
    print("ANTIGRAVITY_NOT_RUNNING")
    exit(1)
}

print("PROBING PID: \(app.processIdentifier)")
let appRef = AXUIElementCreateApplication(app.processIdentifier)

// CGWindowList check
if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
    print("\n--- CGWindowList FOR PID \(app.processIdentifier) ---")
    for winInfo in windowList {
        if let ownerPID = winInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == app.processIdentifier {
            let winName = winInfo[kCGWindowName as String] as? String ?? ""
            let winLayer = winInfo[kCGWindowLayer as String] as? Int ?? 0
            let bounds = winInfo[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let isOnscreen = winInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            print("  WindowID: \(winInfo[kCGWindowNumber as String] ?? 0) | Name: \"\(winName)\" | Layer: \(winLayer) | Onscreen: \(isOnscreen) | Bounds: \(bounds)")
        }
    }
}

print("\n--- AXWindows TREE ---")
if let windows = getAXAttribute(appRef, kAXWindowsAttribute) as? [AXUIElement] {
    print("TOTAL WINDOWS: \(windows.count)")
    for (i, win) in windows.enumerated() {
        print("=== WINDOW [\(i)] ===")
        dumpAllElements(win, depth: 0, maxDepth: 10)
    }
}
