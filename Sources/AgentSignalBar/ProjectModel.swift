import Foundation

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

    public init(
        id: String = UUID().uuidString,
        name: String? = nil,
        rootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
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
    }

    /// Normalizes a path string into a canonical absolute path.
    ///
    /// Handles:
    /// - Tilde expansion (`~` -> home directory)
    /// - Symlink resolution for existing filesystem paths
    /// - Trailing slash stripping (preserving root `/`)
    /// - Redundant `/./` and `/../` resolution
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
