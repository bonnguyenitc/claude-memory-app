import Foundation

public enum MemoryType: String, CaseIterable, Sendable {
    case user, feedback, project, reference
}

public struct MemoryFile: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String?
    public let description: String?
    public let typeValue: String?
    public let body: String
    public let hasFrontmatter: Bool
    public let modified: Date
    /// Targets of `[[name]]` links in the body.
    public let links: [String]

    public var type: MemoryType? { typeValue.flatMap(MemoryType.init(rawValue:)) }
    public var fileName: String { url.lastPathComponent }
    public var slug: String { url.deletingPathExtension().lastPathComponent }
    public var displayName: String { name ?? slug }

    /// Claude Code nests `type` under `metadata`; older files keep it at the top level.
    public static let typePaths: [[String]] = [["metadata", "type"], ["type"]]

    public init(url: URL, text: String, modified: Date) {
        let document = MarkdownDocument(parsing: text)
        self.url = url
        self.modified = modified
        name = document.value(at: ["name"])
        description = document.value(at: ["description"])
        typeValue = Self.typePaths.lazy.compactMap { document.value(at: $0) }.first
        body = document.body
        hasFrontmatter = document.frontmatter != nil
        links = Self.links(in: document.body)
    }

    public func matches(_ query: String) -> Bool {
        [displayName, description ?? "", fileName, body].contains { $0.localizedStandardContains(query) }
    }

    private static func links(in text: String) -> [String] {
        text.matches(of: /\[\[([^\[\]|#\n]+)(?:[|#][^\]\n]*)?\]\]/).map {
            String($0.output.1).trimmingCharacters(in: .whitespaces)
        }
    }
}

public struct ClaudeProject: Identifiable, Hashable, Sendable {
    /// The encoded folder name under `~/.claude/projects`.
    public let id: String
    public let folderURL: URL
    /// The real working directory the folder was created for, when it could be resolved.
    public let path: String?
    /// False when the working directory no longer exists (`path` is then a best guess).
    public let pathExists: Bool
    public let memories: [MemoryFile]
    /// Contents of `memory/MEMORY.md`, or nil when the file doesn't exist.
    public let indexText: String?
    /// Instruction files that exist in the project directory (CLAUDE.md and friends).
    public let instructionFiles: [URL]

    public var memoryDirectory: URL { folderURL.appending(path: "memory", directoryHint: .isDirectory) }
    public var indexURL: URL { memoryDirectory.appending(path: MemoryIndex.fileName) }
    public var index: MemoryIndex? { indexText.map(MemoryIndex.init(text:)) }

    public var displayName: String {
        path.map { ($0 as NSString).lastPathComponent } ?? id
    }

    public var displayPath: String {
        path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? id
    }

    public init(id: String, folderURL: URL, path: String?, pathExists: Bool, memories: [MemoryFile], indexText: String?, instructionFiles: [URL]) {
        self.id = id
        self.folderURL = folderURL
        self.path = path
        self.pathExists = pathExists
        self.memories = memories
        self.indexText = indexText
        self.instructionFiles = instructionFiles
    }
}
