import AppKit
import MemoryCore
import Observation

/// An open file: the text on disk when it was loaded and the text being edited.
struct EditorBuffer {
    var original: String
    var text: String
    var loadedModified: Date?
    /// The file changed on disk while this buffer had unsaved edits.
    var changedOnDisk = false

    var isDirty: Bool { text != original }
}

enum SaveOutcome {
    case saved
    /// The file changed on disk after it was loaded; saving would discard that change.
    case conflict
    case failed
}

@MainActor
@Observable
final class AppModel {
    private(set) var projects: [ClaudeProject] = []
    private(set) var buffers: [URL: EditorBuffer] = [:]
    var errorMessage: String?

    let repository = MemoryRepository()
    @ObservationIgnored private let resolver = ProjectPathResolver()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    var hasUnsavedChanges: Bool { buffers.values.contains(where: \.isDirty) }

    func start() {
        reload()
        watcher = FileWatcher(path: repository.claudeHome.path) { [weak self] paths in
            if paths.contains(where: Self.isRelevant) {
                self?.scheduleReload()
            }
        }
    }

    /// `~/.claude` churns constantly (transcripts, todos); only memory, instruction and settings files matter.
    private static func isRelevant(_ path: String) -> Bool {
        path.contains("/memory/") || path.hasSuffix("/memory") || path.hasSuffix(".md") || path.hasSuffix("/\(ClaudeSettings.fileName)")
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        projects = repository.loadProjects(resolver: resolver)
        for url in buffers.keys {
            refreshBuffer(at: url)
        }
    }

    func project(id: String) -> ClaudeProject? {
        projects.first { $0.id == id }
    }

    func project(containing memoryURL: URL) -> ClaudeProject? {
        let directory = memoryURL.deletingLastPathComponent().standardizedFileURL
        return projects.first { $0.memoryDirectory.standardizedFileURL == directory }
    }

    func memory(at url: URL) -> MemoryFile? {
        project(containing: url)?.memories.first { $0.url == url }
    }

    // MARK: - Buffers

    /// Loads the file into a buffer unless one (possibly with unsaved edits) is already open.
    func open(_ url: URL) {
        if buffers[url] == nil {
            buffers[url] = Self.readBuffer(at: url)
        }
    }

    func updateText(_ text: String, for url: URL) {
        var buffer = buffers[url] ?? Self.readBuffer(at: url)
        buffer.text = text
        buffers[url] = buffer
    }

    func isDirty(_ url: URL) -> Bool {
        buffers[url]?.isDirty ?? false
    }

    func save(_ url: URL, force: Bool = false) -> SaveOutcome {
        guard let buffer = buffers[url] else { return .failed }
        guard force || Self.diskModified(url) == buffer.loadedModified else {
            return .conflict
        }
        var text = buffer.text
        if memory(at: url) != nil {
            text = Self.stampingModified(text)
        }
        do {
            try repository.write(text, to: url)
            buffers[url] = EditorBuffer(original: text, text: text, loadedModified: Self.diskModified(url))
            reload()
            return .saved
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func revert(_ url: URL) {
        buffers[url] = Self.readBuffer(at: url)
    }

    private func refreshBuffer(at url: URL) {
        guard var buffer = buffers[url], Self.diskModified(url) != buffer.loadedModified else { return }
        if buffer.isDirty {
            buffer.changedOnDisk = true
            buffers[url] = buffer
        } else {
            buffers[url] = Self.readBuffer(at: url)
        }
    }

    private static func readBuffer(at url: URL) -> EditorBuffer {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return EditorBuffer(original: text, text: text, loadedModified: diskModified(url))
    }

    private static func diskModified(_ url: URL) -> Date? {
        MemoryRepository.modificationDate(of: url)
    }

    /// Keeps Claude Code's `metadata.modified` timestamp truthful when the file already carries one.
    private static func stampingModified(_ text: String) -> String {
        var document = MarkdownDocument(parsing: text)
        guard document.value(at: ["metadata", "modified"]) != nil else { return text }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        document.setValue(formatter.string(from: .now), at: ["metadata", "modified"])
        return document.serialized()
    }

    // MARK: - Memory operations

    func createMemory(in project: ClaudeProject, slug: String, title: String, description: String, type: MemoryType, body: String) throws -> URL {
        let url = try repository.createMemory(in: project, slug: slug, title: title, description: description, type: type, body: body)
        reload()
        return url
    }

    func delete(_ memory: MemoryFile) {
        guard let project = project(containing: memory.url) else { return }
        perform {
            try repository.deleteMemory(memory, in: project)
            buffers[memory.url] = nil
        }
    }

    func deleteProject(_ project: ClaudeProject) {
        perform {
            try repository.deleteProject(project)
            let folder = project.folderURL.standardizedFileURL.path + "/"
            for url in buffers.keys where url.standardizedFileURL.path.hasPrefix(folder) {
                buffers[url] = nil
            }
        }
        reload()
    }

    func createInstructionFile(at url: URL) {
        perform { try repository.write("", to: url) }
    }

    func addToIndex(_ memory: MemoryFile) {
        guard let project = project(containing: memory.url) else { return }
        perform { try repository.addToIndex(memory, in: project) }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}
