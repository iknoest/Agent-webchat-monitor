import Foundation

// MARK: - ChatGPT URL Parser & Reviewer Identity (M3.2)

/// Extracted canonical identity components from a ChatGPT conversation URL.
public struct ParsedChatGPTReviewerIdentity: Codable, Sendable, Equatable {
    public let conversationId: String
    public let chatgptProjectId: String?
    public let canonicalUrl: String

    public init(conversationId: String, chatgptProjectId: String? = nil, canonicalUrl: String) {
        self.conversationId = conversationId
        self.chatgptProjectId = chatgptProjectId
        self.canonicalUrl = canonicalUrl
    }
}

/// Pure parser extracting canonical ChatGPT conversation identity from full URL strings.
public enum ChatGPTURLParser {
    /// Extracts conversation ID and optional ChatGPT Project ID from supported URL patterns.
    ///
    /// Supported patterns:
    /// - `https://chatgpt.com/c/<conversation-id>`
    /// - `https://chatgpt.com/g/<project-id>/c/<conversation-id>`
    /// - `https://chat.openai.com/c/<conversation-id>`
    /// - `https://chat.openai.com/g/<project-id>/c/<conversation-id>`
    /// - URLs with query strings (`?model=...`) or URL fragments (`#...`)
    ///
    /// Non-conversation URLs (e.g. `https://chatgpt.com/`, `/gpts`, etc.) return `nil`.
    public static func parseReviewerIdentity(from urlString: String) -> ParsedChatGPTReviewerIdentity? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return nil
        }

        guard let host = url.host?.lowercased(),
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "chat.openai.com" else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }

        // Find the "/c/<conversation-id>" segment
        if let cIndex = pathComponents.firstIndex(of: "c"), cIndex + 1 < pathComponents.count {
            let rawConvId = pathComponents[cIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawConvId.isEmpty else { return nil }

            var gProjectId: String? = nil
            if cIndex >= 2 && pathComponents[cIndex - 2] == "g" {
                let gId = pathComponents[cIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !gId.isEmpty {
                    gProjectId = gId
                }
            }

            // Build canonical normalized URL
            let canonicalUrl: String
            if let gId = gProjectId {
                canonicalUrl = "https://chatgpt.com/g/\(gId)/c/\(rawConvId)"
            } else {
                canonicalUrl = "https://chatgpt.com/c/\(rawConvId)"
            }

            return ParsedChatGPTReviewerIdentity(
                conversationId: rawConvId,
                chatgptProjectId: gProjectId,
                canonicalUrl: canonicalUrl
            )
        }

        return nil
    }
}

// MARK: - Reviewer Models (M3.2)

/// Represents the current ChatGPT reviewer conversation assigned to an AgentBridge Project.
public struct ProjectReviewer: Codable, Sendable, Equatable, Hashable {
    /// Stable ChatGPT conversation ID extracted from URL.
    public let conversationId: String

    /// Canonical URL of the reviewer conversation.
    public var url: String

    /// Last-known human-friendly conversation title.
    public var title: String?

    /// Optional ChatGPT Project ID (e.g. "g-p-...") if associated with a custom GPT / workspace project.
    public var chatgptProjectId: String?

    /// Timestamp when this conversation was assigned as current reviewer.
    public let assignedAt: Date

    /// Timestamp when this conversation was last observed active/updated.
    public var lastObservedAt: Date?

    public init(
        conversationId: String,
        url: String,
        title: String? = nil,
        chatgptProjectId: String? = nil,
        assignedAt: Date = Date(),
        lastObservedAt: Date? = nil
    ) {
        self.conversationId = conversationId
        self.url = url
        self.title = title
        self.chatgptProjectId = chatgptProjectId
        self.assignedAt = assignedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// Durable record of a previous ChatGPT reviewer association that was replaced (Migration History).
public struct ReviewerHistoryRecord: Codable, Sendable, Equatable, Hashable {
    /// Stable ChatGPT conversation ID.
    public let conversationId: String

    /// Canonical URL of the conversation.
    public let url: String

    /// Last-known title of the conversation.
    public let title: String?

    /// Optional ChatGPT Project ID.
    public let chatgptProjectId: String?

    /// Timestamp when the conversation was assigned.
    public let assignedAt: Date

    /// Timestamp when the conversation was replaced or unassigned.
    public let replacedAt: Date

    public init(
        conversationId: String,
        url: String,
        title: String? = nil,
        chatgptProjectId: String? = nil,
        assignedAt: Date,
        replacedAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.url = url
        self.title = title
        self.chatgptProjectId = chatgptProjectId
        self.assignedAt = assignedAt
        self.replacedAt = replacedAt
    }
}

/// Live observation status of a Project's current reviewer across open Chrome tabs.
public struct ProjectReviewerLiveStatus: Sendable, Equatable {
    public let isCurrentlyObservable: Bool
    public let activeTabId: Int?
    public let liveTitle: String?
    public let liveStatus: String?
    public let canonicalUrl: String

    public init(
        isCurrentlyObservable: Bool,
        activeTabId: Int? = nil,
        liveTitle: String? = nil,
        liveStatus: String? = nil,
        canonicalUrl: String
    ) {
        self.isCurrentlyObservable = isCurrentlyObservable
        self.activeTabId = activeTabId
        self.liveTitle = liveTitle
        self.liveStatus = liveStatus
        self.canonicalUrl = canonicalUrl
    }
}

// MARK: - Canonical Project Model

/// Canonical representation of an explicitly registered local folder / project root.
public struct Project: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Stable unique identifier for the project.
    public let id: String

    /// Human-friendly display name (defaults to the folder basename if not specified).
    public var name: String

    /// Canonical, normalized absolute filesystem path of the project root.
    public let rootPath: String

    /// Timestamp when the project was registered.
    public let createdAt: Date

    /// Timestamp when the project metadata was last updated.
    public var updatedAt: Date

    /// Currently assigned ChatGPT reviewer conversation (M3.2).
    public var currentReviewer: ProjectReviewer?

    /// Prior reviewer association migration history (M3.2).
    public var reviewerHistory: [ReviewerHistoryRecord]

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        rootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        currentReviewer: ProjectReviewer? = nil,
        reviewerHistory: [ReviewerHistoryRecord] = []
    ) {
        self.id = id
        let canonicalPath = Self.canonicalizePath(rootPath)
        self.rootPath = canonicalPath

        if let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
            self.name = explicitName
        } else {
            let lastComponent = (canonicalPath as NSString).lastPathComponent
            self.name = lastComponent.isEmpty ? "Root" : lastComponent
        }

        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentReviewer = currentReviewer
        self.reviewerHistory = reviewerHistory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let rawPath = try container.decode(String.self, forKey: .rootPath)
        self.rootPath = Self.canonicalizePath(rawPath)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.currentReviewer = try container.decodeIfPresent(ProjectReviewer.self, forKey: .currentReviewer)
        self.reviewerHistory = try container.decodeIfPresent([ReviewerHistoryRecord].self, forKey: .reviewerHistory) ?? []
    }

    /// Evaluates whether the current reviewer is actively open / observable among open Chrome tabs.
    public func liveReviewerStatus(openTabs: [ChatGPTTabInfo]) -> ProjectReviewerLiveStatus? {
        guard let reviewer = currentReviewer else { return nil }

        for tab in openTabs {
            if let parsed = ChatGPTURLParser.parseReviewerIdentity(from: tab.url),
               parsed.conversationId == reviewer.conversationId {
                return ProjectReviewerLiveStatus(
                    isCurrentlyObservable: true,
                    activeTabId: tab.tabId,
                    liveTitle: tab.title,
                    liveStatus: tab.status,
                    canonicalUrl: reviewer.url
                )
            }
        }

        return ProjectReviewerLiveStatus(
            isCurrentlyObservable: false,
            activeTabId: nil,
            liveTitle: reviewer.title,
            liveStatus: nil,
            canonicalUrl: reviewer.url
        )
    }

    /// Normalizes a path string into a canonical absolute path.
    public static func canonicalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1. Expand tilde
        let expanded = NSString(string: trimmed).expandingTildeInPath

        // 2. Standardize path (resolves . and ..)
        let standardized = (expanded as NSString).standardizingPath

        // 3. Resolve symlinks if path exists on disk
        let fileURL = URL(fileURLWithPath: standardized)
        let resolvedPath: String
        if (try? fileURL.checkResourceIsReachable()) == true {
            resolvedPath = fileURL.resolvingSymlinksInPath().path
        } else {
            resolvedPath = standardized
        }

        // 4. Strip trailing slash (unless it is the root `/`)
        if resolvedPath.count > 1 && resolvedPath.hasSuffix("/") {
            return String(resolvedPath.dropLast())
        }
        return resolvedPath
    }
}

/// Versioned schema container for durable project storage in `projects.json`.
public struct ProjectRegistryData: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var projects: [Project]

    public init(version: Int = ProjectRegistryData.currentVersion, projects: [Project] = []) {
        self.version = version
        self.projects = projects
    }
}
