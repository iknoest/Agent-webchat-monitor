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

func inspectElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 8) {
    if depth > maxDepth { return }

    let role = getAXAttribute(element, kAXRoleAttribute) as? String ?? ""
    let subrole = getAXAttribute(element, kAXSubroleAttribute) as? String ?? ""
    let title = getAXAttribute(element, kAXTitleAttribute) as? String ?? ""
    let desc = getAXAttribute(element, kAXDescriptionAttribute) as? String ?? ""
    let value = getAXAttribute(element, kAXValueAttribute) as? String ?? ""
    let identifier = getAXAttribute(element, "AXIdentifier") as? String ?? ""

    let indent = String(repeating: "  ", count: depth)
    let info = "role: \(role) | subrole: \(subrole) | title: \"\(title)\" | desc: \"\(desc)\" | val: \"\(value.prefix(80))\" | id: \"\(identifier)\""
    
    if !role.isEmpty {
        print("\(indent)[\(depth)] \(info)")
    }

    let children = getAXChildren(element)
    for child in children {
        inspectElement(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

let workspace = NSWorkspace.shared
let targetApps = workspace.runningApplications.filter {
    let name = ($0.localizedName ?? "").lowercased()
    let bundle = $0.bundleIdentifier ?? ""
    return name.contains("notification") || bundle.contains("notification")
}

print("FOUND \(targetApps.count) NOTIFICATION APPS:")
for app in targetApps {
    print("\n==========================================")
    print("APP: \(app.localizedName ?? "Unknown") | PID: \(app.processIdentifier) | Bundle: \(app.bundleIdentifier ?? "")")
    print("==========================================")
    let appRef = AXUIElementCreateApplication(app.processIdentifier)
    
    if let windows = getAXAttribute(appRef, kAXWindowsAttribute) as? [AXUIElement] {
        print("TOTAL WINDOWS: \(windows.count)")
        for (i, win) in windows.enumerated() {
            print("--- WINDOW [\(i)] ---")
            inspectElement(win, depth: 0, maxDepth: 6)
        }
    } else {
        print("NO WINDOWS EXPOSED DIRECTLY, PROBING APP ROOT:")
        inspectElement(appRef, depth: 0, maxDepth: 6)
    }
}
