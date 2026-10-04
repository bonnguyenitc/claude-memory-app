import MemoryCore
import Observation
import SwiftUI
import WebKit

/// What the brain map shows. Shared by the settings column and the canvas.
@MainActor
@Observable
final class BrainMapState {
    var projectID: String?
    var typeFilter: MemoryType?
    var showsIndex = true
    var selection: String?

    func graph(in model: AppModel) -> BrainGraph {
        let projects = projectID.map { id in model.projects.filter { $0.id == id } } ?? model.projects
        return BrainGraph(projects: projects, includesIndex: showsIndex, type: typeFilter)
    }
}

// MARK: - Settings column

struct BrainMapPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: BrainMapState
    let onOpen: (BrainGraph.Node) -> Void

    var body: some View {
        let graph = state.graph(in: model)
        let selected = state.selection.flatMap(graph.node(id:))

        Form {
            Section("Show") {
                Picker("Project", selection: $state.projectID) {
                    Text("All projects").tag(String?.none)
                    Divider()
                    ForEach(model.projects.filter { !$0.memories.isEmpty }) { project in
                        Text(project.displayName).tag(String?.some(project.id))
                    }
                }
                Picker("Type", selection: $state.typeFilter) {
                    Text("All types").tag(MemoryType?.none)
                    Divider()
                    ForEach(MemoryType.allCases, id: \.self) { Text($0.rawValue).tag(MemoryType?.some($0)) }
                }
                Toggle("MEMORY.md hubs", isOn: $state.showsIndex)
                    .help("Connect each project's memories to its MEMORY.md")
            }
            Section("Map") {
                LabeledContent("Memories", value: graph.nodes.filter { $0.kind == .memory }.count.formatted())
                LabeledContent("Links", value: graph.edges.filter { $0.kind == .wikilink }.count.formatted())
                Legend()
            }
            if let selected {
                SelectedNodeSection(graph: graph, node: selected, state: state, onOpen: onOpen)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Brain map")
    }
}

private struct Legend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            row(opacity: 0.8, text: "[[wikilink]] between memories")
            row(opacity: 0.3, text: "Listed in MEMORY.md")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func row(opacity: Double, text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Capsule().fill(Color.secondary.opacity(opacity)).frame(width: Spacing.l, height: 2)
            Text(text)
        }
    }
}

private struct SelectedNodeSection: View {
    let graph: BrainGraph
    let node: BrainGraph.Node
    let state: BrainMapState
    let onOpen: (BrainGraph.Node) -> Void

    var body: some View {
        let connected = (graph.neighbors[node.id] ?? []).compactMap(graph.node(id:)).sorted { $0.title < $1.title }
        Section("Selected") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(node.title).fontWeight(.medium)
                if let detail = node.detail, !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                if node.kind == .memory {
                    TypeBadge(value: node.type?.rawValue)
                }
            }
            Button("Open", systemImage: "arrow.up.forward.square") { onOpen(node) }
            if !connected.isEmpty {
                DisclosureGroup("Connected (\(connected.count))") {
                    ForEach(connected) { other in
                        ConnectedRow(node: other) { state.selection = other.id }
                    }
                }
            }
        }
    }
}

/// A neighbour of the selected node: type symbol and title, highlighted on hover.
private struct ConnectedRow: View {
    let node: BrainGraph.Node
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: node.kind == .hub ? "doc.text" : node.type?.symbol ?? "questionmark")
                    .foregroundStyle(.secondary)
                    .frame(width: Spacing.m)
                Text(node.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs + 1)
            .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: Radius.s))
            .motion(.hover, value: isHovering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(node.title)
    }
}

// MARK: - Graph

struct BrainMapView: View {
    @Environment(AppModel.self) private var model
    let state: BrainMapState
    let onOpen: (BrainGraph.Node) -> Void

    var body: some View {
        let graph = state.graph(in: model)
        Group {
            if graph.nodes.isEmpty {
                ContentUnavailableView("No memories to map", systemImage: "brain",
                                       description: Text("Memories linked with [[name]] appear here as connected nodes."))
            } else {
                BrainWebView(
                    graph: graph,
                    selection: state.selection,
                    onSelect: { state.selection = $0 },
                    onOpen: { id in graph.node(id: id).map(onOpen) })
                    .accessibilityLabel("Brain map, \(graph.nodes.count) nodes, \(graph.edges.count) links")
            }
        }
        .navigationTitle("Brain map")
    }
}

/// force-graph running in a web view; see BrainMap/brain.js for the page's side of the protocol.
private struct BrainWebView: NSViewRepresentable {
    let graph: BrainGraph
    let selection: String?
    let onSelect: (String?) -> Void
    let onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "brain")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        if let page = Bundle.module.url(forResource: "brain", withExtension: "html", subdirectory: "BrainMap") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "brain")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: BrainWebView
        weak var webView: WKWebView?
        private var isReady = false
        private var sentGraph: BrainGraph?
        private var sentSelection: String??

        init(_ parent: BrainWebView) {
            self.parent = parent
        }

        func sync() {
            guard isReady else { return }
            if sentGraph != parent.graph {
                sentGraph = parent.graph
                call("setGraph", [Self.payload(of: parent.graph)])
            }
            if sentSelection != .some(parent.selection) {
                sentSelection = .some(parent.selection)
                call("setSelection", [parent.selection ?? NSNull()])
            }
        }

        private static func payload(of graph: BrainGraph) -> [String: Any] {
            [
                "nodes": graph.nodes.map { ["id": $0.id, "title": $0.title, "hub": $0.kind == .hub, "type": $0.type?.rawValue ?? NSNull()] as [String: Any] },
                "links": graph.edges.map { ["source": $0.from, "target": $0.to, "kind": $0.kind == .wikilink ? "wikilink" : "index"] },
            ]
        }

        private func call(_ function: String, _ arguments: [Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("\(function)(...\(json))")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] != nil {
                isReady = true
                sync()
            } else if body.keys.contains("select") {
                let id = body["select"] as? String
                sentSelection = .some(id)
                parent.onSelect(id)
            } else if let id = body["open"] as? String {
                parent.onOpen(id)
            }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
