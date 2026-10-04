import AppKit
import MemoryCore
import SwiftUI

struct MemoryEditorView: View {
    private enum Mode: String, CaseIterable {
        case form = "Form"
        case raw = "Raw"
    }

    @Environment(AppModel.self) private var model
    let url: URL
    @State private var mode = Mode.form
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let buffer = model.buffers[url] {
                if mode == .form {
                    form(MarkdownDocument(parsing: buffer.text))
                } else {
                    MarkdownField(text: textBinding, fileURL: url)
                }
            }
        }
        .editorChrome(url: url, onDelete: model.memory(at: url) == nil ? nil : { confirmingDelete = true })
        .navigationTitle(url.lastPathComponent)
        .toolbar {
            ToolbarItem {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Form edits each field; Raw edits the whole file")
            }
        }
        .confirmationDialog("Delete \(url.lastPathComponent)?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                if let memory = model.memory(at: url) {
                    model.delete(memory)
                }
            }
        } message: {
            Text("The file is moved to the Trash and its line is removed from MEMORY.md.")
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.buffers[url]?.text ?? "" }, set: { model.updateText($0, for: url) })
    }

    private func form(_ document: MarkdownDocument) -> some View {
        let typePath = MemoryFile.typePaths.first { document.value(at: $0) != nil } ?? MemoryFile.typePaths[0]
        let typeValue = document.value(at: typePath) ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("kebab-case-slug", text: field(["name"], in: document))
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Description").foregroundStyle(.secondary)
                    TextField("One-line summary Claude uses to decide whether to read it", text: field(["description"], in: document), axis: .vertical)
                        .lineLimit(1...4)
                }
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Picker("Type", selection: field(typePath, in: document)) {
                        ForEach(MemoryType.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        if MemoryType(rawValue: typeValue) == nil {
                            Text(typeValue.isEmpty ? "(empty)" : "\(typeValue) (invalid)").tag(typeValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Index").foregroundStyle(.secondary)
                    IndexStatus(url: url)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(Spacing.m)

            Divider()
            MarkdownField(text: bodyBinding(document), fileURL: url)
        }
    }

    private func field(_ path: [String], in document: MarkdownDocument) -> Binding<String> {
        Binding(
            get: { document.value(at: path) ?? "" },
            set: { newValue in
                var updated = MarkdownDocument(parsing: model.buffers[url]?.text ?? "")
                updated.setValue(newValue, at: path)
                model.updateText(updated.serialized(), for: url)
            })
    }

    /// The body without the blank line that conventionally follows the frontmatter.
    private func bodyBinding(_ document: MarkdownDocument) -> Binding<String> {
        Binding(
            get: { document.body.hasPrefix("\n") ? String(document.body.dropFirst()) : document.body },
            set: { newValue in
                var updated = MarkdownDocument(parsing: model.buffers[url]?.text ?? "")
                updated.body = (updated.frontmatter == nil ? "" : "\n") + newValue
                model.updateText(updated.serialized(), for: url)
            })
    }
}

private struct IndexStatus: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        if let project = model.project(containing: url), let memory = model.memory(at: url) {
            if project.index?.contains(fileName: memory.fileName) == true {
                Label("Listed in MEMORY.md", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Semantic.ok)
            } else {
                HStack(spacing: Spacing.xs) {
                    Label("Not listed in MEMORY.md", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Semantic.warning)
                    Button("Add") { model.addToIndex(memory) }
                }
            }
        } else {
            Text("Save the file to update").foregroundStyle(.secondary)
        }
    }
}

struct TextFileEditorView: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        Group {
            if model.buffers[url] != nil {
                MarkdownField(text: Binding(get: { model.buffers[url]?.text ?? "" }, set: { model.updateText($0, for: url) }), fileURL: url)
            }
        }
        .editorChrome(url: url)
        .navigationTitle(url.lastPathComponent)
    }
}

/// The markdown workspace wired to the memories of the project the file belongs to.
struct MarkdownField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openDocument) private var openDocument
    @Binding var text: String
    let fileURL: URL

    var body: some View {
        let memories = model.project(containing: fileURL)?.memories ?? []
        MarkdownWorkspace(
            text: $text,
            fileURL: fileURL,
            completionNames: memories.map(\.slug).sorted(),
            knownNames: Set(memories.flatMap { [$0.slug, $0.name].compactMap { $0 } }),
            openWikiLink: { name in
                if let memory = memories.first(where: { $0.slug == name || $0.name == name }) {
                    openDocument(.memory(memory.url))
                }
            })
    }
}

// MARK: - Shared save / revert / conflict chrome

private struct EditorChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    let url: URL
    let onDelete: (() -> Void)?
    @State private var showsConflict = false

    private var buffer: EditorBuffer? { model.buffers[url] }
    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if buffer?.changedOnDisk == true {
                banner("This file changed outside the app while you were editing.", action: "Discard my changes, load from disk") {
                    model.revert(url)
                }
            } else if !exists {
                banner("This file doesn't exist yet. Press Save to create it.", action: nil) {}
            }
            content
        }
        .task { model.open(url) }
        .navigationSubtitle((url.path as NSString).abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItem {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .disabled(!exists)
                    Button("Discard unsaved changes", systemImage: "arrow.uturn.backward") { model.revert(url) }
                        .disabled(buffer?.isDirty != true)
                    if let onDelete {
                        Divider()
                        Button("Move to Trash", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                }
            }
            ToolbarItem {
                Button("Save", systemImage: "square.and.arrow.down") { save(force: false) }
                    .keyboardShortcut("s")
                    .disabled(buffer?.isDirty != true && exists)
            }
        }
        .alert("File changed outside the app", isPresented: $showsConflict) {
            Button("Overwrite with my version", role: .destructive) { save(force: true) }
            Button("Load from disk") { model.revert(url) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude Code may have written to this file after you opened it.")
        }
    }

    private func banner(_ message: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Semantic.warning)
            Text(message)
            Spacer()
            if let action {
                Button(action, action: perform)
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(Semantic.warning.opacity(0.08))
    }

    private func save(force: Bool) {
        if model.save(url, force: force) == .conflict {
            showsConflict = true
        }
    }
}

extension View {
    func editorChrome(url: URL, onDelete: (() -> Void)? = nil) -> some View {
        modifier(EditorChrome(url: url, onDelete: onDelete))
    }
}
