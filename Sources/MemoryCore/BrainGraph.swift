import Foundation

/// The memories of one or more projects as a graph: a node per memory, an edge per
/// `[[wikilink]]` between two memories, and, per project, a hub node for `MEMORY.md`
/// connected to every memory its index lists.
public struct BrainGraph: Hashable, Sendable {
    public struct Node: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case hub, memory
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String?
        public let type: MemoryType?
        /// The memory file, or `MEMORY.md` for a hub.
        public let url: URL
        public let projectID: String
    }

    public struct Edge: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case wikilink, index
        }

        public let from: String
        public let to: String
        public let kind: Kind
    }

    public let nodes: [Node]
    public let edges: [Edge]

    public static let empty = BrainGraph(nodes: [], edges: [])

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public init(projects: [ClaudeProject], includesIndex: Bool = true, type: MemoryType? = nil) {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var connected = Set<[String]>()

        func connect(_ a: String, _ b: String, _ kind: Edge.Kind) {
            guard a != b, connected.insert([min(a, b), max(a, b)]).inserted else { return }
            edges.append(Edge(from: a, to: b, kind: kind))
        }

        for project in projects {
            let memories = project.memories.filter { type == nil || $0.type == type }
            guard !memories.isEmpty else { continue }

            let index = includesIndex ? project.index : nil
            let hubID = Self.hubID(projectID: project.id)
            if index != nil {
                nodes.append(Node(id: hubID, kind: .hub, title: project.displayName, detail: MemoryIndex.fileName,
                                  type: nil, url: project.indexURL, projectID: project.id))
            }
            for memory in memories {
                nodes.append(Node(id: memory.url.path, kind: .memory, title: memory.displayName, detail: memory.description,
                                  type: memory.type, url: memory.url, projectID: project.id))
                if index?.contains(fileName: memory.fileName) == true {
                    connect(hubID, memory.url.path, .index)
                }
            }
            for memory in memories {
                for target in memory.links {
                    if let other = memories.first(where: { $0.slug == target || $0.name == target }) {
                        connect(memory.url.path, other.url.path, .wikilink)
                    }
                }
            }
        }
        self.init(nodes: nodes, edges: edges)
    }

    public static func hubID(projectID: String) -> String {
        "project:" + projectID
    }

    public func node(id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    /// Ids of the nodes directly connected to each node.
    public var neighbors: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for edge in edges {
            result[edge.from, default: []].insert(edge.to)
            result[edge.to, default: []].insert(edge.from)
        }
        return result
    }
}
