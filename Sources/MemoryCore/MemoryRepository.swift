import Foundation

public enum MemoryError: LocalizedError, Equatable {
    case invalidSlug(String)
    case alreadyExists(String)
    case notRestorable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSlug(let slug):
            "“\(slug)” is not kebab-case (only a–z, 0–9 and hyphens)."
        case .alreadyExists(let fileName):
            "\(fileName) already exists in this memory folder."
        case .notRestorable(let name):
            "\(name) can't be put back automatically. Restore it from the Trash in Finder."
        }
    }
}

/// What a delete moved to the Trash, enough to put it back exactly where it was.
public struct TrashRecord: Sendable {
    public let originalURL: URL
    /// Where the item sits in the Trash; nil when the trash implementation can't say.
    public let trashedURL: URL?
    /// The `MEMORY.md` lines that were removed with the memory, verbatim.
    let indexLines: [String]
    let indexURL: URL?
}

/// File-system access to Claude Code's memory and instruction files.
public struct MemoryRepository {
    public let claudeHome: URL
    /// Moves an item to the Trash and returns where it landed.
    private let trashItem: (URL) throws -> URL?

    public init(
        claudeHome: URL = defaultClaudeHome,
        trashItem: @escaping (URL) throws -> URL? = {
            var result: NSURL?
            try FileManager.default.trashItem(at: $0, resultingItemURL: &result)
            return result as URL?
        }
    ) {
        self.claudeHome = claudeHome
        self.trashItem = trashItem
    }

    /// `~/.claude`, or the folder named by `CLAUDE_HOME` (used to run the app on sample data).
    public static var defaultClaudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_HOME"], !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
    }

    public var projectsDirectory: URL { claudeHome.appending(path: "projects", directoryHint: .isDirectory) }
    public var globalInstructionsURL: URL { claudeHome.appending(path: "CLAUDE.md") }
    public var globalSettingsURL: URL { claudeHome.appending(path: ClaudeSettings.fileName) }

    /// Instruction files Claude Code reads from a project directory.
    public static let projectInstructionPaths = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"]

    // MARK: - Loading

    public func loadProjects(resolver: ProjectPathResolver) -> [ClaudeProject] {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { folder in
                let resolution = resolver.resolve(projectFolder: folder)
                let memoryDirectory = folder.appending(path: "memory", directoryHint: .isDirectory)
                let instructionFiles = resolution.flatMap { $0.exists ? $0.path : nil }.map { path in
                    Self.projectInstructionPaths
                        .map { URL(filePath: path, directoryHint: .isDirectory).appending(path: $0) }
                        .filter { fileManager.fileExists(atPath: $0.path) }
                } ?? []
                return ClaudeProject(
                    id: folder.lastPathComponent,
                    folderURL: folder,
                    path: resolution?.path,
                    pathExists: resolution?.exists ?? false,
                    memories: loadMemories(in: memoryDirectory),
                    indexText: try? String(contentsOf: memoryDirectory.appending(path: MemoryIndex.fileName), encoding: .utf8),
                    instructionFiles: instructionFiles)
            }
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }

    private func loadMemories(in directory: URL) -> [MemoryFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != MemoryIndex.fileName }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return MemoryFile(url: url, text: text, modified: Self.modificationDate(of: url) ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    public static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: - Writing

    public func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Why `slug` can't name a new memory in `project`, nil when it can.
    public func slugProblem(_ slug: String, in project: ClaudeProject) -> MemoryError? {
        guard slug.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil else {
            return .invalidSlug(slug)
        }
        let fileName = slug + ".md"
        if FileManager.default.fileExists(atPath: project.memoryDirectory.appending(path: fileName).path) {
            return .alreadyExists(fileName)
        }
        return nil
    }

    @discardableResult
    public func createMemory(
        in project: ClaudeProject,
        slug: String,
        title: String,
        description: String,
        type: MemoryType,
        body: String
    ) throws -> URL {
        if let problem = slugProblem(slug, in: project) {
            throw problem
        }
        let fileName = slug + ".md"
        let url = project.memoryDirectory.appending(path: fileName)

        var document = MarkdownDocument(parsing: "")
        document.setValue(slug, at: ["name"])
        document.setValue(description, at: ["description"])
        document.setValue(type.rawValue, at: ["metadata", "type"])
        document.body = "\n" + body.trimmingCharacters(in: .newlines) + "\n"
        try write(document.serialized(), to: url)

        try write(MemoryIndex.appending(title: title, fileName: fileName, hook: description, to: currentIndexText(of: project)), to: project.indexURL)
        return url
    }

    /// Moves the memory to the Trash and drops its lines from `MEMORY.md`.
    @discardableResult
    public func deleteMemory(_ memory: MemoryFile, in project: ClaudeProject) throws -> TrashRecord {
        let lines = MemoryIndex.lines(for: memory.fileName, in: currentIndexText(of: project))
        let trashed = try trashItem(memory.url)
        try removeIndexEntries(for: memory.fileName, in: project)
        return TrashRecord(originalURL: memory.url, trashedURL: trashed, indexLines: lines, indexURL: project.indexURL)
    }

    /// Moves the project's folder under `~/.claude/projects` (memories and session history) to the Trash.
    /// Files in the project's real working directory, such as its CLAUDE.md, are not touched.
    @discardableResult
    public func deleteProject(_ project: ClaudeProject) throws -> TrashRecord {
        let trashed = try trashItem(project.folderURL)
        return TrashRecord(originalURL: project.folderURL, trashedURL: trashed, indexLines: [], indexURL: nil)
    }

    /// Puts a trashed item back and re-adds the `MEMORY.md` lines it took with it.
    public func restore(_ record: TrashRecord) throws {
        let name = record.originalURL.lastPathComponent
        guard let trashed = record.trashedURL else { throw MemoryError.notRestorable(name) }
        guard !FileManager.default.fileExists(atPath: record.originalURL.path) else { throw MemoryError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: record.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: record.originalURL)
        if let indexURL = record.indexURL, !record.indexLines.isEmpty {
            let text = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
            try write(MemoryIndex.appending(lines: record.indexLines, to: text), to: indexURL)
        }
    }

    public func addToIndex(_ memory: MemoryFile, in project: ClaudeProject) throws {
        let text = MemoryIndex.appending(
            title: memory.displayName,
            fileName: memory.fileName,
            hook: memory.description ?? "",
            to: currentIndexText(of: project))
        try write(text, to: project.indexURL)
    }

    public func removeIndexEntries(for fileName: String, in project: ClaudeProject) throws {
        let text = currentIndexText(of: project)
        let updated = MemoryIndex.removingEntries(for: fileName, from: text)
        if updated != text {
            try write(updated, to: project.indexURL)
        }
    }

    /// Re-reads the index from disk so writes never clobber a change made since the last load.
    private func currentIndexText(of project: ClaudeProject) -> String {
        (try? String(contentsOf: project.indexURL, encoding: .utf8)) ?? ""
    }
}
