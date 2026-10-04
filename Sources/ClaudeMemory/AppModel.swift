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
    /// Why the last save failed; cleared by the next successful save or revert.
    var saveError: String?

    var isDirty: Bool { text != original }
}

enum SaveOutcome {
    case saved
    /// The file changed on disk after it was loaded; saving would discard that change.
    case conflict
    case failed
}

struct OperationFailure: Equatable {
    /// What couldn't be done, phrased for the banner headline.
    let title: String
    let detail: String
}

/// A transient "Moved to the Trash — Undo" message shown at the bottom of the window.
struct UndoToast: Identifiable {
    let id = UUID()
    let message: String
    let undo: @MainActor () -> Void
}

/// Identifies one undo registration so the toast can withdraw exactly that entry.
private final class UndoToken {}

@MainActor
@Observable
final class AppModel {
    private(set) var projects: [ClaudeProject] = []
    private(set) var buffers: [URL: EditorBuffer] = [:]
    /// The last file operation that failed outside an editor, shown as a dismissible banner.
    var failure: OperationFailure?
    private(set) var toast: UndoToast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    let repository = MemoryRepository()
    @ObservationIgnored private let resolver = ProjectPathResolver()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    /// False when `~/.claude/projects` is missing, so an empty list isn't mistaken for "no memories".
    private(set) var projectsFolderMissing = false

    var hasUnsavedChanges: Bool { buffers.values.contains(where: \.isDirty) }

    var unsavedFileNames: [String] {
        buffers.filter { $0.value.isDirty }.map { $0.key.lastPathComponent }.sorted()
    }

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
        projectsFolderMissing = !FileManager.default.fileExists(atPath: repository.projectsDirectory.path)
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
            buffers[url]?.saveError = error.localizedDescription
            return .failed
        }
    }

    func dismissFailure() {
        failure = nil
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

    /// Trashes the memory with no prompt; ⌘Z and the toast both put it back.
    func delete(_ memory: MemoryFile, undoManager: UndoManager?) {
        guard let project = project(containing: memory.url) else { return }
        trash(
            actionName: "Delete Memory", message: "Moved “\(memory.displayName)” to the Trash",
            failureVerb: "move", subject: memory.displayName,
            duration: .seconds(5), undoManager: undoManager,
            operation: {
                let record = try repository.deleteMemory(memory, in: project)
                buffers[memory.url] = nil
                return record
            },
            again: { model in
                if let memory = model.memory(at: memory.url) {
                    model.delete(memory, undoManager: undoManager)
                }
            })
    }

    /// Trashes the project folder; the longer toast reflects that it carries session history.
    func deleteProject(_ project: ClaudeProject, undoManager: UndoManager?) {
        trash(
            actionName: "Delete Project", message: "Moved project “\(project.displayName)” to the Trash",
            failureVerb: "move", subject: project.displayName,
            duration: .seconds(8), undoManager: undoManager,
            operation: {
                let record = try repository.deleteProject(project)
                let folder = project.folderURL.standardizedFileURL.path + "/"
                for url in buffers.keys where url.standardizedFileURL.path.hasPrefix(folder) {
                    buffers[url] = nil
                }
                return record
            },
            again: { model in
                if let project = model.projects.first(where: { $0.folderURL == project.folderURL }) {
                    model.deleteProject(project, undoManager: undoManager)
                }
            })
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func trash(
        actionName: String,
        message: String,
        failureVerb: String,
        subject: String,
        duration: Duration,
        undoManager: UndoManager?,
        operation: () throws -> TrashRecord,
        again: @escaping @MainActor (AppModel) -> Void
    ) {
        let record: TrashRecord
        do {
            record = try operation()
        } catch {
            failure = OperationFailure(title: "Couldn’t \(failureVerb) “\(subject)”", detail: error.localizedDescription)
            reload()
            return
        }
        reload()

        let token = UndoToken()
        undoManager?.registerUndo(withTarget: token) { [token, weak self] _ in
            _ = token
            MainActor.assumeIsolated {
                self?.restore(record, actionName: actionName, undoManager: undoManager, again: again)
            }
        }
        undoManager?.setActionName(actionName)

        let toast = UndoToast(message: message) { [weak self] in
            undoManager?.removeAllActions(withTarget: token)
            self?.restore(record, actionName: actionName, undoManager: nil, again: again)
        }
        self.toast = toast
        AccessibilityNotification.Announcement(message).post()
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }

    /// Puts the item back. Called from the undo stack, it registers the matching redo.
    private func restore(_ record: TrashRecord, actionName: String, undoManager: UndoManager?, again: @escaping @MainActor (AppModel) -> Void) {
        dismissToast()
        perform("Couldn’t put “\(record.originalURL.lastPathComponent)” back") { try repository.restore(record) }
        if FileManager.default.fileExists(atPath: record.originalURL.path), record.originalURL.pathExtension == "md" {
            open(record.originalURL)
        }
        if let undoManager {
            let token = UndoToken()
            undoManager.registerUndo(withTarget: token) { [token, weak self] _ in
                _ = token
                MainActor.assumeIsolated {
                    if let self { again(self) }
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    func createInstructionFile(at url: URL) {
        perform("Couldn’t create \(url.lastPathComponent)") { try repository.write("", to: url) }
    }

    func addToIndex(_ memory: MemoryFile) {
        guard let project = project(containing: memory.url) else { return }
        perform("Couldn’t add “\(memory.displayName)” to MEMORY.md") { try repository.addToIndex(memory, in: project) }
    }

    private func perform(_ failureTitle: String, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            failure = OperationFailure(title: failureTitle, detail: error.localizedDescription)
        }
        reload()
    }
}
