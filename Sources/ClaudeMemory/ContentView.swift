import MemoryCore
import SwiftUI

enum SidebarItem: Hashable {
    case allMemories, brainMap, global
    case project(String)
}

enum DocumentRef: Hashable {
    /// A memory file, edited with the structured form.
    case memory(URL)
    /// Any other markdown file: MEMORY.md, CLAUDE.md.
    case text(URL)
    /// Claude Code's settings.json.
    case settings(URL)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem? = .allMemories
    @State private var document: DocumentRef?
    @State private var creatingIn: ClaudeProject?
    @State private var brainMap = BrainMapState()
    /// A document to select once the sidebar change that reveals it has landed.
    @State private var pendingDocument: DocumentRef?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            Group {
                switch sidebar {
                case .brainMap:
                    BrainMapPanel(state: brainMap, onOpen: open)
                case .global:
                    GlobalFilesView(selection: $document)
                case .project(let id):
                    MemoryListView(scope: .project(id), selection: $document) { creatingIn = $0 }
                case .allMemories, nil:
                    MemoryListView(scope: .all, selection: $document) { creatingIn = $0 }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            if sidebar == .brainMap {
                BrainMapView(state: brainMap, onOpen: open)
            } else {
                documentDetail
            }
        }
        .environment(\.openDocument, OpenDocumentAction { document = $0 })
        .onChange(of: sidebar) {
            document = pendingDocument
            pendingDocument = nil
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                    .help("Reload memories from disk (⌘R)")
            }
        }
        .sheet(item: $creatingIn) { project in
            NewMemorySheet(project: project) { document = .memory($0) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var documentDetail: some View {
        switch document {
        case .memory(let url):
            MemoryEditorView(url: url).id(url)
        case .text(let url):
            TextFileEditorView(url: url).id(url)
        case .settings(let url):
            SettingsEditorView(url: url).id(url)
        case nil:
            ContentUnavailableView("Select a file", systemImage: "doc.text", description: Text("A memory, MEMORY.md, CLAUDE.md or settings.json"))
        }
    }

    /// Leaves the map for the project the node belongs to, with its file selected.
    private func open(_ node: BrainGraph.Node) {
        let ref: DocumentRef = node.kind == .hub ? .text(node.url) : .memory(node.url)
        let target = SidebarItem.project(node.projectID)
        if sidebar == target {
            document = ref
        } else {
            pendingDocument = ref
            sidebar = target
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @AppStorage("showsEmptyProjects") private var showsEmptyProjects = false
    @State private var pendingDelete: ClaudeProject?

    private var visibleProjects: [ClaudeProject] {
        showsEmptyProjects
            ? model.projects
            : model.projects.filter { !$0.memories.isEmpty || $0.indexText != nil || !$0.instructionFiles.isEmpty }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All memories", systemImage: "tray.full")
                    .badge(model.projects.reduce(0) { $0 + $1.memories.count })
                    .tag(SidebarItem.allMemories)
                Label("Brain map", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarItem.brainMap)
                Label("Global", systemImage: "globe")
                    .tag(SidebarItem.global)
            }
            Section("Projects") {
                ForEach(visibleProjects) { project in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.displayName)
                        Text(project.pathExists ? project.displayPath : "≈ \(project.displayPath) (folder deleted)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .badge(project.memories.count)
                    .help(project.displayPath)
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingDelete = project }
                    }
                }
            }
        }
        .onDeleteCommand {
            if case .project(let id) = selection, let project = model.project(id: id) {
                pendingDelete = project
            }
        }
        .confirmationDialog(
            "Delete project \(pendingDelete?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { project in
            Button("Move to Trash", role: .destructive) {
                if selection == .project(project.id) {
                    selection = .allMemories
                }
                model.deleteProject(project)
            }
        } message: { project in
            Text("The folder \(project.id) in ~/.claude/projects, with its \(project.memories.count) memories and session history, is moved to the Trash. Files in the real working directory (such as CLAUDE.md) are not touched.")
        }
        .safeAreaInset(edge: .bottom) {
            Toggle("Show projects without memories", isOn: $showsEmptyProjects)
                .toggleStyle(.checkbox)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
        }
    }
}

struct GlobalFilesView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: DocumentRef?

    var body: some View {
        let url = model.repository.globalInstructionsURL
        let settingsURL = model.repository.globalSettingsURL
        List(selection: $selection) {
            FileRow(url: url, title: "~/.claude/CLAUDE.md", subtitle: "Applies to every project")
                .tag(DocumentRef.text(url))
            FileRow(url: settingsURL, title: "~/.claude/settings.json", subtitle: "Memory, permissions, hooks and more")
                .tag(DocumentRef.settings(settingsURL))
        }
        .navigationTitle("Global")
        .onAppear { selection = .text(url) }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.plaintext")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isDirty(url) {
                Spacer()
                UnsavedDot()
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

struct UnsavedDot: View {
    var body: some View {
        Circle()
            .fill(Semantic.unsaved)
            .frame(width: Spacing.xs, height: Spacing.xs)
            .help("Unsaved")
    }
}
