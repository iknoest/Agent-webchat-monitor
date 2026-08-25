import Foundation

/// Durable local Project Registry for managing canonical local project roots.
public final class ProjectRegistry: @unchecked Sendable {
    public static let shared = ProjectRegistry()

    private let lock = NSLock()
    private var projectsById: [String: Project] = [:]
    private var projectsByCanonicalPath: [String: String] = [:] // canonical rootPath -> project.id
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

    // MARK: - Persistence

    /// Loads project configurations from disk safely.
    public func load() {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let path = storageURL.path

        if !fm.fileExists(atPath: path) {
            projectsById = [:]
            projectsByCanonicalPath = [:]
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let registryData = try decoder.decode(ProjectRegistryData.self, from: data)

            var byId: [String: Project] = [:]
            var byPath: [String: String] = [:]

            for project in registryData.projects {
                let canonical = Project.canonicalizePath(project.rootPath)
                let normalizedProject = Project(
                    id: project.id,
                    name: project.name,
                    rootPath: canonical,
                    createdAt: project.createdAt,
                    updatedAt: project.updatedAt
                )
                byId[normalizedProject.id] = normalizedProject
                byPath[canonical] = normalizedProject.id
            }

            self.projectsById = byId
            self.projectsByCanonicalPath = byPath
        } catch {
            print("⚠️ [ProjectRegistry] Failed to parse projects config from \(path): \(error.localizedDescription)")
            // Backup corrupted file to preserve recoverable data
            let backupPath = "\(path).corrupted.\(Int(Date().timeIntervalSince1970))"
            try? fm.copyItem(atPath: path, toPath: backupPath)
            print("🔒 [ProjectRegistry] Preserved corrupted file backup at \(backupPath)")
            // Safe fallback without crashing
            self.projectsById = [:]
            self.projectsByCanonicalPath = [:]
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

    // MARK: - Registration & Management

    /// Registers a local project root folder.
    ///
    /// If the canonical root path is already registered, returns the existing project
    /// (updating the display name if an explicit new name is provided).
    @discardableResult
    public func registerProject(rootPath: String, name: String? = nil) throws -> Project {
        let canonicalPath = Project.canonicalizePath(rootPath)
        guard !canonicalPath.isEmpty else {
            throw NSError(domain: "ProjectRegistry", code: 1, userInfo: [NSLocalizedDescriptionKey: "Project root path cannot be empty."])
        }

        lock.lock()
        if let existingId = projectsByCanonicalPath[canonicalPath], var existingProject = projectsById[existingId] {
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

        let newProject = Project(
            id: UUID().uuidString,
            name: name,
            rootPath: canonicalPath,
            createdAt: Date(),
            updatedAt: Date()
        )

        projectsById[newProject.id] = newProject
        projectsByCanonicalPath[canonicalPath] = newProject.id
        lock.unlock()

        try save()
        return newProject
    }

    /// Removes a project by its unique ID.
    @discardableResult
    public func removeProject(id: String) throws -> Bool {
        lock.lock()
        guard let project = projectsById.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        projectsByCanonicalPath.removeValue(forKey: project.rootPath)
        lock.unlock()

        try save()
        return true
    }

    /// Removes a project by its root path.
    @discardableResult
    public func removeProject(byRootPath rootPath: String) throws -> Bool {
        let canonicalPath = Project.canonicalizePath(rootPath)
        lock.lock()
        guard let id = projectsByCanonicalPath[canonicalPath] else {
            lock.unlock()
            return false
        }
        projectsById.removeValue(forKey: id)
        projectsByCanonicalPath.removeValue(forKey: canonicalPath)
        lock.unlock()

        try save()
        return true
    }

    // MARK: - Query & Lookup

    /// Looks up a registered project by its unique ID.
    public func getProject(byId id: String) -> Project? {
        lock.lock()
        defer { lock.unlock() }
        return projectsById[id]
    }

    /// Looks up a registered project by its exact canonical root path.
    public func getProject(byRootPath rootPath: String) -> Project? {
        let canonicalPath = Project.canonicalizePath(rootPath)
        lock.lock()
        defer { lock.unlock() }
        guard let id = projectsByCanonicalPath[canonicalPath] else { return nil }
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

    // MARK: - Path Matching Primitives

    /// Deterministically resolves which registered project root contains the given path.
    ///
    /// If nested projects are registered (e.g. `/a/b` and `/a/b/c/d`), the longest
    /// matching registered parent path wins.
    ///
    /// Boundary check guarantees `/a/b-extra` is NOT matched by `/a/b`.
    public func matchProject(forPath filePath: String) -> Project? {
        let canonicalPath = Project.canonicalizePath(filePath)
        guard !canonicalPath.isEmpty else { return nil }

        lock.lock()
        let candidateProjects = Array(projectsById.values)
        lock.unlock()

        var bestMatch: Project? = nil
        var bestMatchLength = -1

        for project in candidateProjects {
            let root = project.rootPath
            let isExactMatch = (canonicalPath == root)
            let isSubpathMatch = canonicalPath.hasPrefix(root == "/" ? "/" : root + "/")

            if isExactMatch || isSubpathMatch {
                if root.count > bestMatchLength {
                    bestMatch = project
                    bestMatchLength = root.count
                }
            }
        }

        return bestMatch
    }

    // MARK: - Test Utilities

    /// Resets all in-memory projects and deletes the backing storage file if in test mode.
    public func resetForTesting() {
        lock.lock()
        projectsById = [:]
        projectsByCanonicalPath = [:]
        lock.unlock()
        if TestEnvironment.isTestRuntime || storageURL.path.contains("AgentSignalBarTest_") {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }
}
