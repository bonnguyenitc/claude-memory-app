import Foundation
import Testing
@testable import MemoryCore

private func memory(_ slug: String, type: String = "user", body: String = "") -> MemoryFile {
    MemoryFile(url: URL(filePath: "/p/memory/\(slug).md"),
               text: "---\nname: \(slug)\ntype: \(type)\n---\n\(body)", modified: .now)
}

private func project(_ memories: [MemoryFile], index: String? = nil, id: String = "-p") -> ClaudeProject {
    ClaudeProject(id: id, folderURL: URL(filePath: "/p"), path: "/p", pathExists: true,
                  memories: memories, indexText: index, instructionFiles: [])
}

@Suite struct BrainGraphTests {
    @Test func linksMemoriesByWikilinkOnce() {
        let graph = BrainGraph(projects: [project([
            memory("a", body: "[[b]] [[b]] [[ghost]] [[a]]"),
            memory("b", body: "[[a]]"),
        ])])
        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.kind == .wikilink)
    }

    @Test func hubConnectsIndexedMemories() {
        let graph = BrainGraph(projects: [project([memory("a"), memory("b")], index: "- [A](a.md) — x\n")])
        let hub = BrainGraph.hubID(projectID: "-p")
        #expect(graph.nodes.filter { $0.kind == .hub }.count == 1)
        #expect(graph.edges.map(\.to) == ["/p/memory/a.md"])
        #expect(graph.edges.first?.from == hub)
        #expect(BrainGraph(projects: [project([memory("a")], index: "- [A](a.md)\n")], includesIndex: false).edges.isEmpty)
    }

    @Test func filtersByTypeAndSkipsEmptyProjects() {
        let projects = [project([memory("a", type: "user"), memory("b", type: "feedback")]), project([], id: "-q")]
        #expect(BrainGraph(projects: projects, type: .feedback).nodes.map(\.title) == ["b"])
        #expect(BrainGraph(projects: projects).nodes.count == 2)
    }
}
