import Foundation
import AppKit

public final class ProviderIconLoader: @unchecked Sendable {
    public static let shared = ProviderIconLoader()

    private var cachedIcons: [AgentID: NSImage] = [:]
    private let lock = NSLock()

    private init() {
        preloadIcons()
    }

    public func preloadIcons() {
        lock.lock()
        defer { lock.unlock() }
        cachedIcons.removeAll()
        for agent in AgentID.allCases {
            if let img = loadIconForAgent(agent) {
                cachedIcons[agent] = img
            }
        }
    }

    public func getIcon(for agent: AgentID) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedIcons[agent] {
            return cached
        }
        if let loaded = loadIconForAgent(agent) {
            cachedIcons[agent] = loaded
            return loaded
        }
        return nil
    }

    private func loadIconForAgent(_ agent: AgentID) -> NSImage? {
        let candidateFilenames: [String]
        switch agent {
        case .chatgpt:
            candidateFilenames = [
                "new-ChatGPT-icon-white-png-large-size.png",
                "chatgpt.png",
                "chatgpt.webp"
            ]
        case .claude:
            candidateFilenames = [
                "claude-code-white-icon.png",
                "Claude-Logo-Starburst-Design-Shape-PNG.png",
                "claude.png"
            ]
        case .codex:
            candidateFilenames = [
                "codex.png",
                "codex.webp"
            ]
        case .antigravity:
            candidateFilenames = [
                "antigravity.png",
                "antigravity.webp"
            ]
        case .copilot:
            candidateFilenames = [
                "github-copilot-white-icon.webp",
                "copilot.png",
                "copilot.webp"
            ]
        }

        let searchDirs: [String] = [
            Bundle.main.resourcePath.map { "\($0)/icons" } ?? "",
            NSString(string: "~/.config/AgentSignalBar/icons").expandingTildeInPath,
            "./agent-white-icon",
            "/Users/ava/Projects/Agent-webchat monitor/agent-white-icon"
        ].filter { !$0.isEmpty }

        for dir in searchDirs {
            for filename in candidateFilenames {
                let fullPath = "\(dir)/\(filename)"
                if FileManager.default.fileExists(atPath: fullPath), let img = NSImage(contentsOfFile: fullPath) {
                    let templateImg = img.copy() as! NSImage
                    templateImg.size = NSSize(width: 14, height: 14)
                    templateImg.isTemplate = true
                    return templateImg
                }
            }
        }
        return nil
    }
}
