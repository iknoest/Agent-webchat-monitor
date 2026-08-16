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

struct NotificationBannerInfo {
    let title: String
    let body: String
    let fullDescription: String
}

func scanBanners(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 6) -> [NotificationBannerInfo] {
    if depth > maxDepth { return [] }

    var results: [NotificationBannerInfo] = []

    let role = getAXAttribute(element, kAXRoleAttribute) as? String ?? ""
    let subrole = getAXAttribute(element, kAXSubroleAttribute) as? String ?? ""
    let desc = getAXAttribute(element, kAXDescriptionAttribute) as? String ?? ""

    if subrole == "AXNotificationCenterBanner" || role == "AXGroup" {
        var titleStr = ""
        var bodyStr = ""
        let children = getAXChildren(element)
        for child in children {
            let cId = getAXAttribute(child, "AXIdentifier") as? String ?? ""
            let cVal = getAXAttribute(child, kAXValueAttribute) as? String ?? ""
            if cId == "title" {
                titleStr = cVal
            } else if cId == "body" {
                bodyStr = cVal
            }
        }
        if !titleStr.isEmpty || !bodyStr.isEmpty || desc.contains("Antigravity") || desc.contains("permission") {
            results.append(NotificationBannerInfo(title: titleStr, body: bodyStr, fullDescription: desc))
        }
    }

    let children = getAXChildren(element)
    for child in children {
        results.append(contentsOf: scanBanners(child, depth: depth + 1, maxDepth: maxDepth))
    }

    return results
}

func checkAntigravityNotification() -> NotificationBannerInfo? {
    let workspace = NSWorkspace.shared
    guard let ncApp = workspace.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.notificationcenterui" || ($0.localizedName ?? "").lowercased().contains("notification center")
    }) else {
        return nil
    }

    let appRef = AXUIElementCreateApplication(ncApp.processIdentifier)
    let banners = scanBanners(appRef)
    
    for b in banners {
        let text = "\(b.title) \(b.body) \(b.fullDescription)".lowercased()
        if (text.contains("antigravity") || text.contains("terminal")) && (text.contains("permission") || text.contains("requesting")) {
            return b
        }
    }
    return nil
}

if let found = checkAntigravityNotification() {
    print("✅ DETECTED ANTIGRAVITY PERMISSION NOTIFICATION:")
    print("   Title: \"\(found.title)\"")
    print("   Body: \"\(found.body)\"")
    print("   Desc: \"\(found.fullDescription)\"")
} else {
    print("ℹ️ NO ACTIVE ANTIGRAVITY PERMISSION NOTIFICATION BANNER DETECTED.")
}
