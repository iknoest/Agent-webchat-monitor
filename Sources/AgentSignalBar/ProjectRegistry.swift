import Foundation

/// Errors produced during Project Registry, Workspace, Workstream, and Reviewer operations.
public enum ProjectRegistryError: Error, LocalizedError, Equatable {
    case emptyPath
    case emptyName
    case projectNotFound(String)
    case workspaceNotFound(String)
    case workstreamNotFound(String)
    case workspaceAlreadyAssigned(path: String, existingProjectId: String, existingProjectName: String)
    case invalidConversationUrl(String)
    case reviewerAlreadyAssigned(conversationId: String, existingProjectId: String, existingProjectName: String)

    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Project or workspace root path cannot be empty."
        case .emptyName:
            return "Project or workstream name cannot be empty."
        case .projectNotFound(let id):
            return "Project with ID '\(id)' not found."
        case .workspaceNotFound(let id):
            return "Workspace with ID '\(id)' not found."
        case .workstreamNotFound(let id):
            return "Workstream with ID '\(id)' not found."
        case .workspaceAlreadyAssigned(let path, _, let name):
            return "Workspace path '\(path)' is already assigned to Project '\(name)'."
        case .invalidConversationUrl(let url):
            return "Cannot extract a valid ChatGPT conversation ID from URL: '\(url)'."
        case .reviewerAlreadyAssigned(let convId, _, let name):
            return "ChatGPT conversation '\(convId)' is already the current reviewer for Project '\(name)'."
        }
    }
}

/// Durable local Project Registry for managing Projects, Workspaces, and Workstreams (M3.1 / M3.6).
public final class ProjectRegistry: @unchecked Sendable {
    public static let shared = ProjectRegistry()

    private let lock = NSLock()
    private var projectsById: [String: Project] = [:]
    private var workspacesByCanonicalPath: [String: (projectId: String, workspaceId: String)] = [:] // canonical path -> (projectId, workspaceId)
    private let storageURL: URL

    /// Returns the active storage URL used by this registry instance.
    public var currentStorageURL: URL {
        return storageURL
    }

    /// Default storage location: `~/.config/AgentSignalBar/projects.json` (or isolated test URL in test mode).
    public static var defaultStorageURL: URL {
        if TestEnvironment.isTestRuntime {
            let tempDir = NSTemporaryDirectory()
            let testUUID = UUID().uuidString
            return URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_\(testUUID).json")
        }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: "\(home)/.config/AgentSignalBar/projects.json")
    }

    /// Initializes a new ProjectRegistry with an optional custom storage URL.
    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.load()
    }

    // MARK: - Persistence & Migration

    /// Loads project configurations from disk safely, supporting Version 1 -> Version 2 migration.
    public func load() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let path = storageURL.path

        if !fm.fileExists(atPath: path) {
            projectsById = [:]
            workspacesByCanonicalPath = [:]
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let registryData = try decoder.decode(ProjectRegistryData.self, from: data)

            var byId: [String: Project] = [:]
            var byWsPath: [String: (projectId: String, workspaceId: String)] = [:]

            for project in registryData.projects {
                var normalizedWorkspaces: [ProjectWorkspace] = []
                for ws in project.workspaces {
                    let canonical = Project.canonicalizePath(ws.path)
                    let normWs = ProjectWorkspace(
                        id: ws.id,
                        path: canonical,
                        name: ws.name,
                        isPrimary: ws.isPrimary,
                        createdAt: ws.createdAt
                    )
                    normalizedWorkspaces.append(normWs)
                    byWsPath[canonical] = (projectId: project.id, workspaceId: normWs.id)
                }

                // If no workspace is primary, designate the first one as primary
                if !normalizedWorkspaces.isEmpty && !normalizedWorkspaces.contains(where: { $0.isPrimary }) {
                    normalizedWorkspaces[0].isPrimary = true
                }

                // Cleanse workstream workspace scoping to enforce exclusivity
                // If a workspaceId appears in >1 workstream (ambiguous conflict from legacy data),
                // remove it from all workstreams so it becomes unassigned without guessing.
                let validWorkspaceIdSet = Set(normalizedWorkspaces.map { $0.id })
                var workspaceIdCount: [String: Int] = [:]
                for st in project.workstreams {
                    for wsId in Set(st.workspaceIds) {
                        if validWorkspaceIdSet.contains(wsId) {
                            workspaceIdCount[wsId, default: 0] += 1
                        }
                    }
                }

                var normalizedWorkstreams: [ProjectWorkstream] = []
                for st in project.workstreams {
                    let cleanWsIds = st.workspaceIds.filter { wsId in
                        validWorkspaceIdSet.contains(wsId) && (workspaceIdCount[wsId] == 1)
                    }
                    var seenWsIds = Set<String>()
                    var dedupedWsIds: [String] = []
                    for wsId in cleanWsIds {
                        if !seenWsIds.contains(wsId) {
                            seenWsIds.insert(wsId)
                            dedupedWsIds.append(wsId)
                        }
                    }
                    var normSt = st
                    normSt.workspaceIds = dedupedWsIds
                    normalizedWorkstreams.append(normSt)
                }

                let normalizedProject = Project(
                    id: project.id,
                    name: project.name,
                    workspaces: normalizedWorkspaces,
                    workstreams: normalizedWorkstreams,
                    gitRepository: project.gitRepository,
                    recentSessions: project.recentSessions,
                    createdAt: project.createdAt,
                    updatedAt: project.updatedAt
                )
                byId[normalizedProject.id] = normalizedProject
            }

            self.projectsById = byId
            self.workspacesByCanonicalPath = byWsPath
        } catch {
            print("⚠️ [ProjectRegistry] Failed to parse projects config from \(path): \(error.localizedDescription)")
            // Backup corrupted file to preserve recoverable data
            let backupPath = "\(path).corrupted.\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: path, toPath: backupPath)
            print("🔒 [ProjectRegistry] Preserved corrupted file backup at \(backupPath)")
            // Safe fallback without crashing
            self.projectsById = [:]
            self.workspacesByCanonicalPath = [:]
        }
    }

    /// Saves project configurations to disk atomically.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let dirURL = storageURL.deletingLastPathComponent()

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let sortedProjects = Array(projectsById.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let registryData = ProjectRegistryData(version: ProjectRegistryData.currentVersion, projects: sortedProjects)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(registryData)
        try data.write(to: storageURL, options: [.atomic])
    }

    // MARK: - Project Creation & Registration

    /// Creates a new Project explicitly (M3.6 Self-Service Project Formation).
    @discardableResult
    public func createProject(
        name: String,
        initialWorkspacePath: String? = nil,
        initialWorkstreamName: String? = nil
    ) throws -> Project {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProjectRegistryError.emptyName
        }

        lock.lock()
        let newProjectId = UUID().uuidString
        var workspaces: [ProjectWorkspace] = []
        var workstreams: [ProjectWorkstream] = []

        if let wsPath = initialWorkspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !wsPath.isEmpty {
            let canonicalPath = Project.canonicalizePath(wsPath)
            if let (existingPid, _) = workspacesByCanonicalPath[canonicalPath], let existingProj = projectsById[existingPid] {
                lock.unlock()
                throw ProjectRegistryError.workspaceAlreadyAssigned(
                    path: canonicalPath,
                    existingProjectId: existingPid,
                    existingProjectName: existingProj.name
                )
            }
            let ws = ProjectWorkspace(path: canonicalPath, name: nil, isPrimary: true)
            workspaces.append(ws)
            workspacesByCanonicalPath[canonicalPath] = (projectId: newProjectId, workspaceId: ws.id)
        }

        let streamName = initialWorkstreamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Main"
        let primaryId = workspaces.first?.id
        let defaultStream = ProjectWorkstream(
            id: UUID().uuidString,
            name: streamName.isEmpty ? "Main" : streamName,
            currentReviewer: nil,
            reviewerHistory: [],
            workspaceIds: primaryId != nil ? [primaryId!] : []
        )
        workstreams.append(defaultStream)

        let newProject = Project(
            id: newProjectId,
            name: cleanName,
            workspaces: workspaces,
            workstreams: workstreams,
            gitRepository: workspaces.first.flatMap { ProjectGitDetector.detect(at: $0.path) },
            createdAt: Date(),
            updatedAt: Date()
        )

        projectsById[newProject.id] = newProject
        lock.unlock()

        try save()
        return newProject
    }

    /// Registers a local project root folder (M3.1-M3.5 compatibility).
    ///
    /// If the canonical root path is already registered as a workspace, returns the existing project
    /// (updating the display name if an explicit new name is provided).
    @discardableResult
    public func registerProject(rootPath: String, name: String? = nil) throws -> Project {
        let canonicalPath = Project.canonicalizePath(rootPath)
        guard !canonicalPath.isEmpty else {
            throw ProjectRegistryError.emptyPath
        }

        lock.lock()
        if let (existingId, _) = workspacesByCanonicalPath[canonicalPath], var existingProject = projectsById[existingId] {
            if let newName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty, newName != existingProject.name {
                existingProject.name = newName
                existingProject.updatedAt = Date()
                projectsById[existingId] = existingProject
                lock.unlock()
                try save()
                return existingProject
            }
            lock.unlock()
            return existingProject
        }

        let newProjectId = UUID().uuidString
        let primaryWs = ProjectWorkspace(path: canonicalPath, name: nil, isPrimary: true)
        let defaultWs = ProjectWorkstream(
            id: UUID().uuidString,
            name: "Main",
            currentReviewer: nil,
            reviewerHistory: [],
            workspaceIds: [primaryWs.id]
        )

        let cleanName: String
        if let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
            cleanName = explicitName
        } else {
            let lastComponent = (canonicalPath as NSString).lastPathComponent
            cleanName = lastComponent.isEmpty ? "Root" : lastComponent
        }

        let newProject = Project(
            id: newProjectId,
            name: cleanName,
            workspaces: [primaryWs],
            workstreams: [defaultWs],
            gitRepository: ProjectGitDetector.detect(at: canonicalPath),
            createdAt: Date(),
            updatedAt: Date()
        )

        projectsById[newProject.id] = newProject
        workspacesByCanonicalPath[canonicalPath] = (projectId: newProjectId, workspaceId: primaryWs.id)
        lock.unlock()

        try save()
        return newProject
    }

    /// Renames an existing Project.
    @discardableResult
    public func renameProject(id: String, newName: String) throws -> Project {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProjectRegistryError.emptyName
        }

        lock.lock()
        guard var project = projectsById[id] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(id)
        }
        project.name = cleanName
        project.updatedAt = Date()
        projectsById[id] = project
        lock.unlock()

        try save()
        return project
    }

    /// Removes a project by its unique ID, clearing all its workspace ownerships.
    @discardableResult
    public func removeProject(id: String) throws -> Bool {
        lock.lock()
        guard let project = projectsById.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        for ws in project.workspaces {
            workspacesByCanonicalPath.removeValue(forKey: ws.path)
        }
        lock.unlock()

        try save()
        return true
    }

    /// Alias for removeProject(id:).
    @discardableResult
    public func deleteProject(id: String) throws -> Bool {
        return try removeProject(id: id)
    }

    /// Removes a project by any of its workspace paths.
    @discardableResult
    public func removeProject(byRootPath rootPath: String) throws -> Bool {
        let canonicalPath = Project.canonicalizePath(rootPath)
        lock.lock()
        guard let (projectId, _) = workspacesByCanonicalPath[canonicalPath] else {
            lock.unlock()
            return false
        }
        lock.unlock()
        return try removeProject(id: projectId)
    }

    // MARK: - Multi-Workspace Management (M3.6)

    /// Adds a local workspace folder to an existing Project.
    @discardableResult
    public func addWorkspace(
        toProjectId projectId: String,
        path: String,
        name: String? = nil,
        isPrimary: Bool = false
    ) throws -> ProjectWorkspace {
        let canonicalPath = Project.canonicalizePath(path)
        guard !canonicalPath.isEmpty else {
            throw ProjectRegistryError.emptyPath
        }

        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        // Workspace uniqueness invariant: belongs to at most ONE project
        if let (existingPid, existingWsId) = workspacesByCanonicalPath[canonicalPath] {
            if existingPid == projectId {
                // Already in this project: return existing
                if let existingWs = project.workspaces.first(where: { $0.id == existingWsId }) {
                    lock.unlock()
                    return existingWs
                }
            } else {
                let existingName = projectsById[existingPid]?.name ?? "Another Project"
                lock.unlock()
                throw ProjectRegistryError.workspaceAlreadyAssigned(
                    path: canonicalPath,
                    existingProjectId: existingPid,
                    existingProjectName: existingName
                )
            }
        }

        let makePrimary = isPrimary || project.workspaces.isEmpty
        if makePrimary {
            for i in 0..<project.workspaces.count {
                project.workspaces[i].isPrimary = false
            }
        }

        let newWs = ProjectWorkspace(
            id: UUID().uuidString,
            path: canonicalPath,
            name: name,
            isPrimary: makePrimary
        )

        project.workspaces.append(newWs)
        project.updatedAt = Date()
        if project.gitRepository == nil {
            project.gitRepository = ProjectGitDetector.detect(at: canonicalPath)
        }

        projectsById[projectId] = project
        workspacesByCanonicalPath[canonicalPath] = (projectId: projectId, workspaceId: newWs.id)
        lock.unlock()

        try save()
        return newWs
    }

    /// Removes a workspace from a Project.
    @discardableResult
    public func removeWorkspace(workspaceId: String, fromProjectId projectId: String) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard let wsIndex = project.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            lock.unlock()
            throw ProjectRegistryError.workspaceNotFound(workspaceId)
        }

        let removedWs = project.workspaces.remove(at: wsIndex)
        workspacesByCanonicalPath.removeValue(forKey: removedWs.path)

        // If removed workspace was primary and workspaces remain, designate the first remaining as primary
        if removedWs.isPrimary && !project.workspaces.isEmpty {
            project.workspaces[0].isPrimary = true
        }

        // Clean up workstream workspace scoping
        for i in 0..<project.workstreams.count {
            project.workstreams[i].workspaceIds.removeAll(where: { $0 == workspaceId })
        }

        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return project
    }

    /// Designates a workspace as the primary workspace for a Project.
    @discardableResult
    public func setPrimaryWorkspace(workspaceId: String, inProjectId projectId: String) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard project.workspaces.contains(where: { $0.id == workspaceId }) else {
            lock.unlock()
            throw ProjectRegistryError.workspaceNotFound(workspaceId)
        }

        for i in 0..<project.workspaces.count {
            project.workspaces[i].isPrimary = (project.workspaces[i].id == workspaceId)
        }

        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return project
    }

    // MARK: - Workstream Management (M3.6)

    /// Adds a workstream to an existing Project.
    @discardableResult
    public func addWorkstream(
        toProjectId projectId: String,
        name: String,
        workspaceIds: [String] = []
    ) throws -> ProjectWorkstream {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProjectRegistryError.emptyName
        }

        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        // Exclusive auto-move: sanitize workspaceIds and remove from other workstreams in this project
        var sanitizedWorkspaceIds: [String] = []
        for wsId in workspaceIds {
            if project.workspaces.contains(where: { $0.id == wsId }) {
                for i in 0..<project.workstreams.count {
                    if let rmIdx = project.workstreams[i].workspaceIds.firstIndex(of: wsId) {
                        project.workstreams[i].workspaceIds.remove(at: rmIdx)
                        project.workstreams[i].updatedAt = Date()
                    }
                }
                if !sanitizedWorkspaceIds.contains(wsId) {
                    sanitizedWorkspaceIds.append(wsId)
                }
            }
        }

        let newStream = ProjectWorkstream(
            id: UUID().uuidString,
            name: cleanName,
            currentReviewer: nil,
            reviewerHistory: [],
            workspaceIds: sanitizedWorkspaceIds
        )

        project.workstreams.append(newStream)
        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return newStream
    }

    /// Renames a workstream.
    @discardableResult
    public func renameWorkstream(
        workstreamId: String,
        inProjectId projectId: String,
        newName: String
    ) throws -> ProjectWorkstream {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProjectRegistryError.emptyName
        }

        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard let streamIndex = project.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        project.workstreams[streamIndex].name = cleanName
        project.workstreams[streamIndex].updatedAt = Date()
        project.updatedAt = Date()
        let updatedStream = project.workstreams[streamIndex]
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return updatedStream
    }

    /// Removes a workstream from a Project.
    @discardableResult
    public func removeWorkstream(workstreamId: String, fromProjectId projectId: String) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard let streamIndex = project.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        project.workstreams.remove(at: streamIndex)
        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return project
    }

    /// Assigns a workspace to a workstream's scope.
    @discardableResult
    public func assignWorkspace(
        workspaceId: String,
        toWorkstreamId workstreamId: String,
        inProjectId projectId: String
    ) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        guard project.workspaces.contains(where: { $0.id == workspaceId }) else {
            lock.unlock()
            throw ProjectRegistryError.workspaceNotFound(workspaceId)
        }
        guard let streamIdx = project.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        // Exclusive auto-move:
        // 1. Remove workspaceId from any other workstream in the same project
        var modified = false
        for otherIdx in 0..<project.workstreams.count {
            if otherIdx != streamIdx {
                if let rmIdx = project.workstreams[otherIdx].workspaceIds.firstIndex(of: workspaceId) {
                    project.workstreams[otherIdx].workspaceIds.remove(at: rmIdx)
                    project.workstreams[otherIdx].updatedAt = Date()
                    modified = true
                }
            }
        }

        // 2. Assign workspaceId to target workstream
        if !project.workstreams[streamIdx].workspaceIds.contains(workspaceId) {
            project.workstreams[streamIdx].workspaceIds.append(workspaceId)
            project.workstreams[streamIdx].updatedAt = Date()
            modified = true
        }

        if modified {
            project.updatedAt = Date()
            projectsById[projectId] = project
        }
        lock.unlock()

        try save()
        return project
    }

    /// Removes a workspace from a workstream's scope.
    @discardableResult
    public func unassignWorkspace(
        workspaceId: String,
        fromWorkstreamId workstreamId: String,
        inProjectId projectId: String
    ) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        guard let streamIdx = project.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        if let idx = project.workstreams[streamIdx].workspaceIds.firstIndex(of: workspaceId) {
            project.workstreams[streamIdx].workspaceIds.remove(at: idx)
            project.workstreams[streamIdx].updatedAt = Date()
            project.updatedAt = Date()
            projectsById[projectId] = project
        }
        lock.unlock()

        try save()
        return project
    }

    /// Toggles a workspace in a workstream's scope.
    @discardableResult
    public func toggleWorkstreamWorkspace(
        workspaceId: String,
        workstreamId: String,
        inProjectId projectId: String
    ) throws -> Project {
        lock.lock()
        guard let project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        guard let stream = project.workstreams.first(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }
        let isAssigned = stream.workspaceIds.contains(workspaceId)
        lock.unlock()

        if isAssigned {
            return try unassignWorkspace(workspaceId: workspaceId, fromWorkstreamId: workstreamId, inProjectId: projectId)
        } else {
            return try assignWorkspace(workspaceId: workspaceId, toWorkstreamId: workstreamId, inProjectId: projectId)
        }
    }

    // MARK: - Workstream Reviewer Management (M3.6)

    /// Assigns a ChatGPT conversation as current reviewer for a specific Workstream.
    @discardableResult
    public func assignReviewer(
        toWorkstreamId workstreamId: String,
        inProjectId projectId: String,
        url: String,
        title: String? = nil
    ) throws -> Project {
        guard let parsed = ChatGPTURLParser.parseReviewerIdentity(from: url) else {
            throw ProjectRegistryError.invalidConversationUrl(url)
        }

        lock.lock()
        guard var targetProject = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard let targetIndex = targetProject.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        // Global Cardinality Invariant: Is this conversationId already currentReviewer in ANY workstream in ANY project?
        for (otherPid, otherProject) in projectsById {
            for otherWs in otherProject.workstreams {
                if otherPid == projectId && otherWs.id == workstreamId { continue }
                if let existingRev = otherWs.currentReviewer, existingRev.conversationId == parsed.conversationId {
                    let existingScopeName = (otherProject.workstreams.count <= 1 || otherWs.name == "Main" || otherWs.name == "Default") ? otherProject.name : "\(otherProject.name) / \(otherWs.name)"
                    lock.unlock()
                    throw ProjectRegistryError.reviewerAlreadyAssigned(
                        conversationId: parsed.conversationId,
                        existingProjectId: otherPid,
                        existingProjectName: existingScopeName
                    )
                }
            }
        }

        var workstream = targetProject.workstreams[targetIndex]

        // If same conversation is already assigned to THIS workstream, update title/url
        if let current = workstream.currentReviewer, current.conversationId == parsed.conversationId {
            workstream.currentReviewer?.url = parsed.canonicalUrl
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                workstream.currentReviewer?.title = t
            }
            if let gId = parsed.chatgptProjectId {
                workstream.currentReviewer?.chatgptProjectId = gId
            }
            workstream.currentReviewer?.lastObservedAt = Date()
            workstream.updatedAt = Date()
            targetProject.workstreams[targetIndex] = workstream
            targetProject.updatedAt = Date()
            projectsById[projectId] = targetProject
            lock.unlock()
            try save()
            return targetProject
        }

        // Migration/Replacement: Archive previous reviewer to workstream history
        if let oldReviewer = workstream.currentReviewer {
            let historyRecord = ReviewerHistoryRecord(
                conversationId: oldReviewer.conversationId,
                url: oldReviewer.url,
                title: oldReviewer.title,
                chatgptProjectId: oldReviewer.chatgptProjectId,
                assignedAt: oldReviewer.assignedAt,
                replacedAt: Date()
            )
            workstream.reviewerHistory.append(historyRecord)
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newReviewer = ProjectReviewer(
            conversationId: parsed.conversationId,
            url: parsed.canonicalUrl,
            title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
            chatgptProjectId: parsed.chatgptProjectId,
            assignedAt: Date(),
            lastObservedAt: Date()
        )

        workstream.currentReviewer = newReviewer
        workstream.updatedAt = Date()
        targetProject.workstreams[targetIndex] = workstream
        targetProject.updatedAt = Date()
        projectsById[projectId] = targetProject
        lock.unlock()

        try save()
        return targetProject
    }

    /// Removes current reviewer from a specific Workstream, archiving it to reviewerHistory.
    @discardableResult
    public func removeReviewer(
        fromWorkstreamId workstreamId: String,
        inProjectId projectId: String
    ) throws -> Project {
        lock.lock()
        guard var targetProject = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        guard let targetIndex = targetProject.workstreams.firstIndex(where: { $0.id == workstreamId }) else {
            lock.unlock()
            throw ProjectRegistryError.workstreamNotFound(workstreamId)
        }

        var workstream = targetProject.workstreams[targetIndex]
        if let oldReviewer = workstream.currentReviewer {
            let historyRecord = ReviewerHistoryRecord(
                conversationId: oldReviewer.conversationId,
                url: oldReviewer.url,
                title: oldReviewer.title,
                chatgptProjectId: oldReviewer.chatgptProjectId,
                assignedAt: oldReviewer.assignedAt,
                replacedAt: Date()
            )
            workstream.reviewerHistory.append(historyRecord)
            workstream.currentReviewer = nil
            workstream.updatedAt = Date()
            targetProject.workstreams[targetIndex] = workstream
            targetProject.updatedAt = Date()
            projectsById[projectId] = targetProject
            lock.unlock()
            try save()
            return targetProject
        }

        lock.unlock()
        return targetProject
    }

    // MARK: - Reviewer Management (M3.2 / Simple Project Compatibility)

    /// Assigns a ChatGPT conversation to the primary / first workstream of a Project.
    @discardableResult
    public func assignReviewer(
        toProjectId projectId: String,
        url: String,
        title: String? = nil
    ) throws -> Project {
        lock.lock()
        guard let project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        let targetWorkstreamId: String
        if let firstStream = project.workstreams.first {
            targetWorkstreamId = firstStream.id
            lock.unlock()
        } else {
            lock.unlock()
            let newStream = try addWorkstream(toProjectId: projectId, name: "Main")
            targetWorkstreamId = newStream.id
        }
        return try assignReviewer(toWorkstreamId: targetWorkstreamId, inProjectId: projectId, url: url, title: title)
    }

    /// Removes current reviewer from the primary / first workstream of a Project.
    @discardableResult
    public func removeReviewer(fromProjectId projectId: String) throws -> Project {
        lock.lock()
        guard let project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        guard let firstStream = project.workstreams.first(where: { $0.currentReviewer != nil }) ?? project.workstreams.first else {
            lock.unlock()
            return project
        }
        let targetWorkstreamId = firstStream.id
        lock.unlock()
        return try removeReviewer(fromWorkstreamId: targetWorkstreamId, inProjectId: projectId)
    }

    /// Finds which project and workstream currently has the specified conversation ID as reviewer.
    public func findProject(byReviewerConversationId conversationId: String) -> (project: Project, workstream: ProjectWorkstream)? {
        lock.lock()
        defer { lock.unlock() }
        for project in projectsById.values {
            for ws in project.workstreams {
                if let rev = ws.currentReviewer, rev.conversationId == conversationId {
                    return (project, ws)
                }
            }
        }
        return nil
    }

    // MARK: - Git Repository Association (M3.4)

    /// Refreshes local Git repository metadata for a project across its workspaces.
    @discardableResult
    public func refreshGitRepository(forProjectId projectId: String) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }

        let detected = project.liveGitRepository
        if project.gitRepository != detected {
            project.gitRepository = detected
            project.updatedAt = Date()
            projectsById[projectId] = project
            lock.unlock()
            try save()
            return project
        } else {
            lock.unlock()
            return project
        }
    }

    // MARK: - Query & Lookup

    /// Looks up a registered project by its unique ID.
    public func getProject(byId id: String) -> Project? {
        lock.lock()
        defer { lock.unlock() }
        return projectsById[id]
    }

    /// Looks up a registered project by exact canonical workspace path.
    public func getProject(byRootPath rootPath: String) -> Project? {
        let canonicalPath = Project.canonicalizePath(rootPath)
        lock.lock()
        defer { lock.unlock() }
        guard let (id, _) = workspacesByCanonicalPath[canonicalPath] else { return nil }
        return projectsById[id]
    }

    /// Returns all registered projects, sorted by name.
    public func getAllProjects() -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        return Array(projectsById.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Number of registered projects.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return projectsById.count
    }

    // MARK: - Path Matching Primitives (M3.3 / M3.6)

    /// Deterministically resolves which registered workspace contains the given path.
    ///
    /// If nested workspaces are registered (e.g. `/a/b` and `/a/b/c/d`), the longest
    /// matching registered parent workspace path wins.
    ///
    /// Boundary check guarantees `/a/b-extra` is NOT matched by `/a/b`.
    public func matchWorkspace(forPath filePath: String) -> (project: Project, workspace: ProjectWorkspace)? {
        let canonicalPath = Project.canonicalizePath(filePath)
        guard !canonicalPath.isEmpty else { return nil }

        lock.lock()
        let candidateProjects = Array(projectsById.values)
        lock.unlock()

        var bestMatch: (project: Project, workspace: ProjectWorkspace)? = nil
        var bestMatchLength = -1

        for project in candidateProjects {
            for workspace in project.workspaces {
                let wsPath = workspace.path
                let isExactMatch = (canonicalPath == wsPath)
                let isSubpathMatch = canonicalPath.hasPrefix(wsPath == "/" ? "/" : wsPath + "/")

                if isExactMatch || isSubpathMatch {
                    if wsPath.count > bestMatchLength {
                        bestMatch = (project, workspace)
                        bestMatchLength = wsPath.count
                    }
                }
            }
        }

        return bestMatch
    }

    /// Deterministically resolves which registered Project contains the given path.
    public func matchProject(forPath filePath: String) -> Project? {
        return matchWorkspace(forPath: filePath)?.project
    }

    // MARK: - Recent Session Continuity (M3.7)

    /// Records or updates the single most-recent session snapshot for a (Project × Workstream × Provider).
    /// If workstream is nil, records as a Project-level unassigned workstream snapshot.
    @discardableResult
    public func recordRecentSession(from session: AgentSessionInfo) -> Project? {
        guard let project = session.resolveProject(using: self) else {
            return nil
        }
        let resolvedWorkstream = session.resolveWorkstream(using: self)
        return recordRecentSession(from: session, inProjectId: project.id, workstreamId: resolvedWorkstream?.id)
    }

    /// Records or updates a snapshot in a specific project with optional workstream ID.
    @discardableResult
    public func recordRecentSession(
        from session: AgentSessionInfo,
        inProjectId projectId: String,
        workstreamId: String?
    ) -> Project? {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            return nil
        }

        let snapshot = ProjectRecentSession.from(session: session, projectId: projectId, workstreamId: workstreamId)

        // Bounded invariant: Retain at most ONE most-recent snapshot per (Project × optional Workstream × Provider).
        // If a snapshot exists for the same (provider, workstreamId), replace it.
        if let existingIdx = project.recentSessions.firstIndex(where: {
            $0.provider == session.provider && $0.workstreamId == workstreamId
        }) {
            project.recentSessions[existingIdx] = snapshot
        } else if let sameSessionIdx = project.recentSessions.firstIndex(where: {
            $0.sessionId == session.sessionId && $0.provider == session.provider
        }) {
            // Same stable session updated its workstream/state
            project.recentSessions[sameSessionIdx] = snapshot
        } else {
            project.recentSessions.append(snapshot)
        }

        // Sort by lastUpdated descending
        project.recentSessions.sort(by: { $0.lastUpdated > $1.lastUpdated })

        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try? save()
        return project
    }

    /// Returns the recent sessions for a given project ID.
    public func getRecentSessions(forProjectId projectId: String) -> [ProjectRecentSession] {
        lock.lock()
        defer { lock.unlock() }
        return projectsById[projectId]?.recentSessions ?? []
    }

    /// Clears all recent sessions for a project.
    @discardableResult
    public func clearRecentSessions(forProjectId projectId: String) throws -> Project {
        lock.lock()
        guard var project = projectsById[projectId] else {
            lock.unlock()
            throw ProjectRegistryError.projectNotFound(projectId)
        }
        project.recentSessions.removeAll()
        project.updatedAt = Date()
        projectsById[projectId] = project
        lock.unlock()

        try save()
        return project
    }

    // MARK: - Test Utilities

    /// Resets all in-memory projects and deletes the backing storage file if in test mode.
    public func resetForTesting() {
        lock.lock()
        projectsById = [:]
        workspacesByCanonicalPath = [:]
        lock.unlock()
        if TestEnvironment.isTestRuntime || storageURL.path.contains("AgentSignalBarTest_") {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }
}
