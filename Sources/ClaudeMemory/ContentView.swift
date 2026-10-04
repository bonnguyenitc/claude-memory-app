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
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                UndoToastView(toast: toast)
                    .padding(Spacing.l)
                    .transition(.opacity.combined(with: .offset(y: Spacing.s)))
            }
        }
        .motion(.layout, value: model.toast?.id)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var documentDetail: some View {
        Group {
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
        .transition(.opacity)
        .motion(.fade, value: document)
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
    @Environment(\.undoManager) private var undoManager
    @Binding var selection: SidebarItem?
    @AppStorage("showsEmptyProjects") private var showsEmptyProjects = false

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
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { trash(project) }
                    }
                }
            }
        }
        .onDeleteCommand {
            if case .project(let id) = selection, let project = model.project(id: id) {
                trash(project)
            }
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

extension SidebarView {
    private func trash(_ project: ClaudeProject) {
        if selection == .project(project.id) {
            selection = .allMemories
        }
        model.deleteProject(project, undoManager: undoManager)
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
        .motion(.fade, value: model.isDirty(url))
    }
}

struct UnsavedDot: View {
    var body: some View {
        Circle()
            .fill(Semantic.unsaved)
            .frame(width: Spacing.xs, height: Spacing.xs)
            .help("Unsaved")
            .transition(.opacity)
    }
}

/// Bottom-of-window confirmation of a trash action, with the one-click way back.
struct UndoToastView: View {
    @Environment(AppModel.self) private var model
    let toast: UndoToast

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(toast.message)
                .lineLimit(1)
            Button("Undo", action: toast.undo)
                .buttonStyle(.link)
            Button("Dismiss", systemImage: "xmark") { model.dismissToast() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
