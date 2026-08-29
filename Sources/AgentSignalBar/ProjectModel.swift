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

// MARK: - GitHub Repository URL Parser & Identity (M3.4)

/// Canonical identity representation of an associated GitHub repository.
public struct ProjectGitHubRepository: Codable, Sendable, Equatable, Hashable {
    /// Owner / organization name (e.g. "iknoest", "google", "apple").
    public let owner: String

    /// Repository name (e.g. "Agent-webchat-monitor").
    public let repository: String

    /// Normalized owner/repo identity string (e.g. "iknoest/Agent-webchat-monitor").
    public var fullName: String {
        return "\(owner)/\(repository)"
    }

    /// Canonical web URL (e.g. "https://github.com/iknoest/Agent-webchat-monitor").
    public let canonicalUrl: String

    /// Git remote name where this repository was detected (e.g. "origin").
    public let detectedRemoteName: String

    /// Timestamp when this repository association was detected/verified.
    public let detectedAt: Date

    public init(
        owner: String,
        repository: String,
        canonicalUrl: String,
        detectedRemoteName: String = "origin",
        detectedAt: Date = Date()
    ) {
        self.owner = owner
        self.repository = repository
        self.canonicalUrl = canonicalUrl
        self.detectedRemoteName = detectedRemoteName
        self.detectedAt = detectedAt
    }
}

/// Pure parser extracting normalized GitHub repository identity from remote URLs.
public enum GitHubURLParser {
    /// Parses a git remote URL into a canonical `ProjectGitHubRepository` if it points to GitHub.
    ///
    /// Supported formats:
    /// - `git@github.com:owner/repo.git`
    /// - `git@github.com:owner/repo`
    /// - `https://github.com/owner/repo.git`
    /// - `https://github.com/owner/repo`
    /// - `http://github.com/owner/repo`
    /// - `ssh://git@github.com/owner/repo.git`
    /// - `ssh://git@github.com/owner/repo`
    ///
    /// Non-GitHub URLs (GitLab, Bitbucket, local filesystem paths, malformed URLs) return `nil`.
    public static func parseRepository(from remoteUrl: String, remoteName: String = "origin") -> ProjectGitHubRepository? {
        let trimmed = remoteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. SSH format: git@github.com:owner/repo(.git)
        if trimmed.hasPrefix("git@github.com:") {
            let pathPart = String(trimmed.dropFirst("git@github.com:".count))
            return parseOwnerRepoPath(pathPart, remoteName: remoteName)
        }

        // 2. SSH protocol: ssh://git@github.com/owner/repo(.git)
        if trimmed.hasPrefix("ssh://git@github.com/") {
            let pathPart = String(trimmed.dropFirst("ssh://git@github.com/".count))
            return parseOwnerRepoPath(pathPart, remoteName: remoteName)
        }

        // 3. HTTP / HTTPS / standard URL
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            guard host == "github.com" || host == "www.github.com" else {
                return nil
            }

            let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            guard components.count == 2 else { return nil }

            let owner = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var repo = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if repo.hasSuffix(".git") {
                repo = String(repo.dropLast(4))
            }

            guard isValidGitIdentifier(owner), isValidGitIdentifier(repo) else {
                return nil
            }

            return ProjectGitHubRepository(
                owner: owner,
                repository: repo,
                canonicalUrl: "https://github.com/\(owner)/\(repo)",
                detectedRemoteName: remoteName
            )
        }

        return nil
    }

    private static func parseOwnerRepoPath(_ path: String, remoteName: String) -> ProjectGitHubRepository? {
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        let parts = cleanPath.split(separator: "/")
        guard parts.count == 2 else { return nil }

        let owner = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        var repo = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard isValidGitIdentifier(owner), isValidGitIdentifier(repo) else {
            return nil
        }

        return ProjectGitHubRepository(
            owner: owner,
            repository: repo,
            canonicalUrl: "https://github.com/\(owner)/\(repo)",
            detectedRemoteName: remoteName
        )
    }

    private static func isValidGitIdentifier(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let invalidChars = CharacterSet(charactersIn: " \t\r\n/\\:?#@!$%^&*()[]{}|<>\"'")
        return string.rangeOfCharacter(from: invalidChars) == nil
    }
}

/// Detects local Git configuration and remotes for a project directory without blocking subprocesses.
public enum ProjectGitDetector {
    /// Inspects the local Git repository at `rootPath` and extracts its authoritative GitHub repository if present.
    ///
    /// Reads `.git/config` directly from disk (fast, isolated, zero subprocess execution).
    /// Supports git submodules and worktree `.git` file pointers (`gitdir: ...`).
    /// Follows remote selection rules:
    /// - If `origin` remote exists and points to GitHub -> uses `origin`
    /// - If only one remote exists and it points to GitHub -> uses it
    /// - If multiple remotes exist and none is `origin`, or they point to conflicting distinct GitHub repos -> returns nil
    /// - If rootPath has no .git -> returns nil
    public static func detect(at rootPath: String) -> ProjectGitHubRepository? {
        let canonicalRoot = Project.canonicalizePath(rootPath)
        let gitPath = (canonicalRoot as NSString).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return nil
        }

        let configFilePath: String
        if isDirectory.boolValue {
            configFilePath = (gitPath as NSString).appendingPathComponent("config")
        } else {
            // .git file (worktree or submodule): format "gitdir: <path>"
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8) else {
                return nil
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("gitdir:") else { return nil }
            var relOrAbs = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !relOrAbs.hasPrefix("/") {
                relOrAbs = (canonicalRoot as NSString).appendingPathComponent(String(relOrAbs))
            }
            configFilePath = (Project.canonicalizePath(relOrAbs) as NSString).appendingPathComponent("config")
        }

        guard FileManager.default.fileExists(atPath: configFilePath),
              let configContent = try? String(contentsOfFile: configFilePath, encoding: .utf8) else {
            return nil
        }

        let remotes = parseGitConfigFile(configContent)
        return resolveAuthoritativeGitHubRemote(from: remotes)
    }

    /// Pure parser for git config format extracting remote names and their URLs.
    public static func parseGitConfigFile(_ configContent: String) -> [String: String] {
        var remotes: [String: String] = [:]
        var currentSectionRemote: String? = nil

        for line in configContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if section.hasPrefix("remote ") {
                    let rawName = section.dropFirst("remote ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanName = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentSectionRemote = cleanName
                } else {
                    currentSectionRemote = nil
                }
            } else if let current = currentSectionRemote, trimmed.hasPrefix("url") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "url" {
                    let urlVal = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !urlVal.isEmpty {
                        remotes[current] = urlVal
                    }
                }
            }
        }

        return remotes
    }

    /// Resolves the authoritative GitHub repository from a dictionary of [remoteName: url].
    public static func resolveAuthoritativeGitHubRemote(from remotes: [String: String]) -> ProjectGitHubRepository? {
        guard !remotes.isEmpty else { return nil }

        // 1. If "origin" exists and is a valid GitHub URL, it is authoritative by Git convention
        if let originUrl = remotes["origin"], let parsed = GitHubURLParser.parseRepository(from: originUrl, remoteName: "origin") {
            return parsed
        }

        // 2. Filter all remotes that point to GitHub
        var githubRemotes: [ProjectGitHubRepository] = []
        for (name, url) in remotes {
            if let parsed = GitHubURLParser.parseRepository(from: url, remoteName: name) {
                githubRemotes.append(parsed)
            }
        }

        if githubRemotes.count == 1 {
            return githubRemotes.first
        }

        // 3. If multiple distinct GitHub repos exist and neither is origin, fail closed (ambiguous)
        return nil
    }
}

// MARK: - Canonical Project Model

/// Canonical representation of an explicitly registered local folder / project root.
// MARK: - Project Workspaces & Workstreams (M3.6)

/// Represents a canonical local filesystem workspace root belonging to an AgentBridge Project.
public struct ProjectWorkspace: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Stable unique identifier for the workspace.
    public let id: String

    /// Canonical, normalized absolute filesystem path of the workspace root.
    public var path: String

    /// Optional human-friendly label for this workspace (e.g. "Main Repo", "Codex Worktree").
    public var name: String?

    /// Whether this workspace is the designated primary workspace for the project.
    public var isPrimary: Bool

    /// Timestamp when this workspace was added to the project.
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        path: String,
        name: String? = nil,
        isPrimary: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.path = Project.canonicalizePath(path)
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (cleanName?.isEmpty == false) ? cleanName : nil
        self.isPrimary = isPrimary
        self.createdAt = createdAt
    }
}

/// Represents an authority and coordination boundary inside an AgentBridge Project (e.g. Workstream A/B/C).
public struct ProjectWorkstream: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Stable unique identifier for the workstream.
    public let id: String

    /// Human-friendly display name (e.g. "A — Discovery / Scoring", "Main").
    public var name: String

    /// Currently assigned ChatGPT reviewer conversation for this workstream (M3.6).
    public var currentReviewer: ProjectReviewer?

    /// Prior reviewer association migration history for this workstream (M3.6).
    public var reviewerHistory: [ReviewerHistoryRecord]

    /// Zero or more workspace IDs scoped specifically to this workstream.
    public var workspaceIds: [String]

    /// Timestamp when this workstream was created.
    public let createdAt: Date

    /// Timestamp when this workstream metadata was last updated.
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        currentReviewer: ProjectReviewer? = nil,
        reviewerHistory: [ReviewerHistoryRecord] = [],
        workspaceIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? "Default" : cleanName
        self.currentReviewer = currentReviewer
        self.reviewerHistory = reviewerHistory
        self.workspaceIds = workspaceIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Evaluates whether this workstream's reviewer is actively open / observable among open Chrome tabs.
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
}

// MARK: - Core Project Entity (M3.1 / M3.6 Multi-Workspace & Workstream Model)

/// Represents a logical project boundary containing one or more workspaces, workstreams, and sessions.
public struct Project: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Stable unique identifier for the project.
    public let id: String

    /// Human-friendly display name.
    public var name: String

    /// All canonical filesystem workspaces belonging to this project (M3.6).
    public var workspaces: [ProjectWorkspace]

    /// All coordination / authority workstreams belonging to this project (M3.6).
    public var workstreams: [ProjectWorkstream]

    /// Optional associated GitHub repository metadata (M3.4).
    public var gitRepository: ProjectGitHubRepository?

    /// Timestamp when the project was registered.
    public let createdAt: Date

    /// Timestamp when the project metadata was last updated.
    public var updatedAt: Date

    // MARK: - Backward-Compatible Computed Properties

    /// Canonical primary root path of the project (M3.1 compatibility).
    public var rootPath: String {
        return primaryWorkspace?.path ?? workspaces.first?.path ?? ""
    }

    /// Designated primary workspace, or first workspace.
    public var primaryWorkspace: ProjectWorkspace? {
        return workspaces.first(where: { $0.isPrimary }) ?? workspaces.first
    }

    /// Current reviewer of the primary / first workstream (M3.2 compatibility).
    public var currentReviewer: ProjectReviewer? {
        get {
            return workstreams.first(where: { $0.currentReviewer != nil })?.currentReviewer
        }
        set {
            if let newRev = newValue {
                if workstreams.isEmpty {
                    workstreams.append(ProjectWorkstream(id: "default", name: "Main", currentReviewer: newRev))
                } else {
                    workstreams[0].currentReviewer = newRev
                    workstreams[0].updatedAt = Date()
                }
            } else {
                for i in 0..<workstreams.count {
                    workstreams[i].currentReviewer = nil
                    workstreams[i].updatedAt = Date()
                }
            }
        }
    }

    /// Prior reviewer association migration history aggregated across workstreams (M3.2 compatibility).
    public var reviewerHistory: [ReviewerHistoryRecord] {
        return workstreams.flatMap { $0.reviewerHistory }
    }

    // MARK: - Initializers

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        workspaces: [ProjectWorkspace] = [],
        workstreams: [ProjectWorkstream] = [],
        gitRepository: ProjectGitHubRepository? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaces = workspaces
        self.workstreams = workstreams
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        if let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
            self.name = explicitName
        } else if let primary = workspaces.first {
            let lastComponent = (primary.path as NSString).lastPathComponent
            self.name = lastComponent.isEmpty ? "Root" : lastComponent
        } else {
            self.name = "Project"
        }

        if let explicitGit = gitRepository {
            self.gitRepository = explicitGit
        } else if let primary = workspaces.first {
            self.gitRepository = ProjectGitDetector.detect(at: primary.path)
        } else {
            self.gitRepository = nil
        }
    }

    /// Convenience initializer for single-workspace registration (M3.1-M3.5 compatibility).
    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        rootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        currentReviewer: ProjectReviewer? = nil,
        reviewerHistory: [ReviewerHistoryRecord] = [],
        gitRepository: ProjectGitHubRepository? = nil
    ) {
        let canonicalPath = Self.canonicalizePath(rootPath)
        let primaryWs = ProjectWorkspace(path: canonicalPath, name: nil, isPrimary: true, createdAt: createdAt)
        let defaultWs = ProjectWorkstream(
            id: "default",
            name: "Main",
            currentReviewer: currentReviewer,
            reviewerHistory: reviewerHistory,
            workspaceIds: [primaryWs.id],
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        self.id = id
        self.workspaces = [primaryWs]
        self.workstreams = [defaultWs]
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        if let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
            self.name = explicitName
        } else {
            let lastComponent = (canonicalPath as NSString).lastPathComponent
            self.name = lastComponent.isEmpty ? "Root" : lastComponent
        }

        self.gitRepository = gitRepository ?? ProjectGitDetector.detect(at: canonicalPath)
    }

    // MARK: - Decodable with Version 1 -> Version 2 Schema Migration

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case workspaces
        case workstreams
        case gitRepository
        case createdAt
        case updatedAt
        // Legacy v1 keys:
        case rootPath
        case currentReviewer
        case reviewerHistory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.gitRepository = try container.decodeIfPresent(ProjectGitHubRepository.self, forKey: .gitRepository)

        // 1. Decode or migrate Workspaces
        if let decodedWorkspaces = try container.decodeIfPresent([ProjectWorkspace].self, forKey: .workspaces), !decodedWorkspaces.isEmpty {
            self.workspaces = decodedWorkspaces.map { ws in
                ProjectWorkspace(
                    id: ws.id,
                    path: Self.canonicalizePath(ws.path),
                    name: ws.name,
                    isPrimary: ws.isPrimary,
                    createdAt: ws.createdAt
                )
            }
        } else if let rawRootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) {
            let canonical = Self.canonicalizePath(rawRootPath)
            let primaryWs = ProjectWorkspace(path: canonical, name: nil, isPrimary: true, createdAt: self.createdAt)
            self.workspaces = [primaryWs]
        } else {
            self.workspaces = []
        }

        // 2. Decode or migrate Workstreams
        if let decodedWorkstreams = try container.decodeIfPresent([ProjectWorkstream].self, forKey: .workstreams), !decodedWorkstreams.isEmpty {
            self.workstreams = decodedWorkstreams
        } else {
            let legacyReviewer = try container.decodeIfPresent(ProjectReviewer.self, forKey: .currentReviewer)
            let legacyHistory = try container.decodeIfPresent([ReviewerHistoryRecord].self, forKey: .reviewerHistory) ?? []
            let primaryId = self.workspaces.first?.id
            let defaultWs = ProjectWorkstream(
                id: "default",
                name: "Main",
                currentReviewer: legacyReviewer,
                reviewerHistory: legacyHistory,
                workspaceIds: primaryId != nil ? [primaryId!] : [],
                createdAt: self.createdAt,
                updatedAt: self.updatedAt
            )
            self.workstreams = [defaultWs]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(workstreams, forKey: .workstreams)
        try container.encodeIfPresent(gitRepository, forKey: .gitRepository)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Live Observation & Evaluation

    /// Evaluates live local Git repository status across the project's workspaces.
    public var liveGitRepository: ProjectGitHubRepository? {
        if let primary = primaryWorkspace, let repo = ProjectGitDetector.detect(at: primary.path) {
            return repo
        }
        for ws in workspaces {
            if let repo = ProjectGitDetector.detect(at: ws.path) {
                return repo
            }
        }
        return nil
    }

    /// Evaluates whether any workstream reviewer is actively open / observable among open Chrome tabs.
    public func liveReviewerStatus(openTabs: [ChatGPTTabInfo]) -> ProjectReviewerLiveStatus? {
        for ws in workstreams {
            if let st = ws.liveReviewerStatus(openTabs: openTabs), st.isCurrentlyObservable {
                return st
            }
        }
        return workstreams.first?.liveReviewerStatus(openTabs: openTabs)
    }

    /// Aggregated state summary of a Project for top-level switcher display (M3.5 / M3.6).
    public struct StatusSummary: Sendable, Equatable {
        public let status: AgentStatus
        public let totalSessions: Int
        public let blockedCount: Int
        public let workingCount: Int
        public let doneCount: Int
        public let idleCount: Int
        public let isReviewerOpen: Bool
        public let reviewerTitle: String?

        public var statusBadgeText: String {
            if blockedCount > 0 {
                return "⚠️ \(blockedCount) Needs You"
            }
            if workingCount > 0 {
                return "\(workingCount) Working"
            }
            if doneCount > 0 {
                return "\(doneCount) Ready"
            }
            if totalSessions > 0 {
                return "\(totalSessions) Active"
            }
            return "No Active Sessions"
        }

        public init(
            status: AgentStatus,
            totalSessions: Int,
            blockedCount: Int,
            workingCount: Int,
            doneCount: Int,
            idleCount: Int,
            isReviewerOpen: Bool,
            reviewerTitle: String? = nil
        ) {
            self.status = status
            self.totalSessions = totalSessions
            self.blockedCount = blockedCount
            self.workingCount = workingCount
            self.doneCount = doneCount
            self.idleCount = idleCount
            self.isReviewerOpen = isReviewerOpen
            self.reviewerTitle = reviewerTitle
        }
    }

    /// Computes the aggregated status summary for this project using canonical lifecycle priority (M3.5 / M3.6).
    public func statusSummary(sessions: [AgentSessionInfo], openTabs: [ChatGPTTabInfo] = []) -> StatusSummary {
        var blocked = 0
        var working = 0
        var done = 0
        var idle = 0

        for sess in sessions {
            switch sess.status {
            case .blocked:
                blocked += 1
            case .working:
                working += 1
            case .done:
                done += 1
            case .idle, .off, .quotaExceeded:
                idle += 1
            }
        }

        var isRevOpen = false
        var revTitle: String? = nil

        for ws in workstreams {
            if let liveRev = ws.liveReviewerStatus(openTabs: openTabs) {
                if liveRev.isCurrentlyObservable {
                    isRevOpen = true
                    revTitle = liveRev.liveTitle
                    break
                } else if revTitle == nil {
                    revTitle = liveRev.liveTitle
                }
            }
        }

        let aggregate: AgentStatus
        if blocked > 0 {
            aggregate = .blocked
        } else if working > 0 {
            aggregate = .working
        } else if done > 0 {
            aggregate = .done
        } else {
            aggregate = .idle
        }

        return StatusSummary(
            status: aggregate,
            totalSessions: sessions.count,
            blockedCount: blocked,
            workingCount: working,
            doneCount: done,
            idleCount: idle,
            isReviewerOpen: isRevOpen,
            reviewerTitle: revTitle
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

/// Versioned schema container for durable project storage in `projects.json` (M3.6 Version 2).
public struct ProjectRegistryData: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var projects: [Project]

    public init(version: Int = ProjectRegistryData.currentVersion, projects: [Project] = []) {
        self.version = version
        self.projects = projects
    }
}

public typealias ProjectStatusSummary = Project.StatusSummary
