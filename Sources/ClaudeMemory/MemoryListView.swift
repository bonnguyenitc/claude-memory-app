import MemoryCore
import SwiftUI

struct MemoryListView: View {
    enum Scope: Equatable {
        case all
        case project(String)
    }

    @Environment(AppModel.self) private var model
    let scope: Scope
    @Binding var selection: DocumentRef?
    let onCreate: (ClaudeProject) -> Void

    @State private var search = ""
    @State private var typeFilter: MemoryType?
    @State private var pendingDelete: MemoryFile?

    private var scopedProjects: [ClaudeProject] {
        switch scope {
        case .all: model.projects
        case .project(let id): model.project(id: id).map { [$0] } ?? []
        }
    }

    private func visibleMemories(of project: ClaudeProject) -> [MemoryFile] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return project.memories.filter { memory in
            (typeFilter == nil || memory.type == typeFilter) && (query.isEmpty || memory.matches(query))
        }
    }

    var body: some View {
        let groups = scopedProjects
            .map { ($0, visibleMemories(of: $0)) }
            .filter { !$0.1.isEmpty }

        List(selection: $selection) {
            if case .project = scope, let project = scopedProjects.first {
                ProjectFilesSection(project: project)
            }
            ForEach(groups, id: \.0.id) { project, memories in
                Section(scope == .all ? project.displayName : "Memory (\(memories.count))") {
                    ForEach(memories) { memory in
                        MemoryRow(memory: memory)
                            .tag(DocumentRef.memory(memory.url))
                            .contextMenu {
                                Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingDelete = memory }
                            }
                            .swipeActions {
                                Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingDelete = memory }
                            }
                    }
                }
            }
        }
        .onDeleteCommand {
            if case .memory(let url) = selection, let memory = groups.lazy.flatMap(\.1).first(where: { $0.url == url }) {
                pendingDelete = memory
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.fileName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { memory in
            Button("Move to Trash", role: .destructive) {
                if selection == .memory(memory.url) {
                    selection = nil
                }
                model.delete(memory)
            }
        } message: { _ in
            Text("The file is moved to the Trash and its line is removed from MEMORY.md.")
        }
        .overlay {
            if groups.isEmpty {
                if search.isEmpty && typeFilter == nil {
                    ContentUnavailableView("No memories yet", systemImage: "brain")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .searchable(text: $search, prompt: "Search memories")
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup {
                Picker("Type", selection: $typeFilter) {
                    Text("All types").tag(MemoryType?.none)
                    Divider()
                    ForEach(MemoryType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(MemoryType?.some(type))
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by memory type")

                if case .project = scope, let project = scopedProjects.first {
                    Button("New memory", systemImage: "plus") { onCreate(project) }
                        .keyboardShortcut("n")
                }
            }
        }
    }

    private var navigationTitle: String {
        switch scope {
        case .all: "All memories"
        case .project(let id): model.project(id: id)?.displayName ?? id
        }
    }
}

/// MEMORY.md and the project's CLAUDE.md files, shown above its memories.
private struct ProjectFilesSection: View {
    @Environment(AppModel.self) private var model
    let project: ClaudeProject

    var body: some View {
        Section("Files") {
            FileRow(url: project.indexURL, title: MemoryIndex.fileName,
                    subtitle: project.indexText == nil ? "Missing" : "\(project.index?.entries.count ?? 0) entries")
                .tag(DocumentRef.text(project.indexURL))
            ForEach(project.instructionFiles, id: \.self) { url in
                FileRow(url: url, title: relativePath(url), subtitle: "Project instructions")
                    .tag(DocumentRef.text(url))
            }
            if let path = project.path, project.pathExists, project.instructionFiles.isEmpty {
                Button("Create CLAUDE.md", systemImage: "plus") {
                    model.createInstructionFile(at: URL(filePath: path, directoryHint: .isDirectory).appending(path: "CLAUDE.md"))
                }
                .buttonStyle(.link)
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let path = project.path else { return url.lastPathComponent }
        return String(url.path.dropFirst(path.count + 1))
    }
}

struct MemoryRow: View {
    @Environment(AppModel.self) private var model
    let memory: MemoryFile

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(memory.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if model.isDirty(memory.url) {
                    UnsavedDot()
                }
            }
            if let description = memory.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: Spacing.xs) {
                TypeBadge(value: memory.typeValue)
                Text(memory.modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// Type is carried by symbol and label in one neutral color, not by a color per type.
struct TypeBadge: View {
    let value: String?

    private var type: MemoryType? { value.flatMap(MemoryType.init(rawValue:)) }

    var body: some View {
        Label(value ?? "no type", systemImage: type?.symbol ?? "questionmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
