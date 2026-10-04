import Foundation
import Testing
@testable import MemoryCore

private let claudeStyle = """
---
name: no-git-stash
description: "Never git stash: it drops staged state"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 38f42985
---

Body with [[other-memory]] and [[missing|alias]].
"""

@Suite struct MarkdownDocumentTests {
    @Test func roundTripsUntouchedFiles() {
        #expect(MarkdownDocument(parsing: claudeStyle).serialized() == claudeStyle)
        #expect(MarkdownDocument(parsing: "no frontmatter\n").serialized() == "no frontmatter\n")
    }

    @Test func readsFlatNestedAndQuotedValues() {
        let document = MarkdownDocument(parsing: claudeStyle)
        #expect(document.value(at: ["name"]) == "no-git-stash")
        #expect(document.value(at: ["description"]) == "Never git stash: it drops staged state")
        #expect(document.value(at: ["metadata", "type"]) == "feedback")
        #expect(document.value(at: ["metadata", "missing"]) == nil)
    }

    @Test func readsBlockScalars() {
        let document = MarkdownDocument(parsing: "---\ndescription: >\n  folded\n  text\nname: x\n---\n")
        #expect(document.value(at: ["description"]) == "folded text")
        #expect(document.value(at: ["name"]) == "x")
    }

    @Test func setValueChangesOnlyThatLine() {
        var document = MarkdownDocument(parsing: claudeStyle)
        document.setValue("project", at: ["metadata", "type"])
        document.setValue("plain words", at: ["description"])
        let expected = claudeStyle
            .replacingOccurrences(of: "  type: feedback", with: "  type: project")
            .replacingOccurrences(of: "description: \"Never git stash: it drops staged state\"", with: "description: plain words")
        #expect(document.serialized() == expected)
    }

    @Test func setValueReplacesBlockScalarContinuation() {
        var document = MarkdownDocument(parsing: "---\ndescription: |\n  a\n  b\nname: x\n---\nbody")
        document.setValue("new", at: ["description"])
        #expect(document.serialized() == "---\ndescription: new\nname: x\n---\nbody")
    }

    @Test func setValueInsertsMissingKeys() {
        var document = MarkdownDocument(parsing: "---\nname: x\nmetadata:\n    a: 1\n---\n")
        document.setValue("user", at: ["metadata", "type"])
        document.setValue("d", at: ["description"])
        #expect(document.frontmatter == ["name: x", "metadata:", "    a: 1", "    type: user", "description: d"])

        var bare = MarkdownDocument(parsing: "body")
        bare.setValue("user", at: ["metadata", "type"])
        #expect(bare.serialized() == "---\nmetadata:\n  type: user\n---\nbody")
    }

    @Test(arguments: [
        ("plain", "plain"),
        ("", "\"\""),
        ("a: b", "\"a: b\""),
        ("- dash", "\"- dash\""),
        ("yes", "\"yes\""),
        ("42", "\"42\""),
        ("say \"hi\"\nnow", "\"say \\\"hi\\\"\\nnow\""),
    ])
    func quotesWhenYamlNeedsIt(input: String, expected: String) {
        #expect(MarkdownDocument.yamlScalar(input) == expected)
        let parsed = MarkdownDocument(parsing: "---\nk: \(expected)\n---\n")
        #expect(parsed.value(at: ["k"]) == input)
    }
}

@Suite struct MemoryIndexTests {
    let text = """
    # Memory Index

    - [Stash rule](no-git-stash.md) — never stash
    - [Spaced](my%20file.md)
    Not an entry
    """

    @Test func parsesEntries() {
        let index = MemoryIndex(text: text)
        #expect(index.entries.map(\.target) == ["no-git-stash.md", "my file.md"])
        #expect(index.entries.first?.title == "Stash rule")
        #expect(index.entries.first?.hook == "never stash")
        #expect(index.entries.first?.line == 2)
    }

    @Test func appendsAndRemoves() {
        let appended = MemoryIndex.appending(title: "New", fileName: "new.md", hook: "hook", to: text)
        #expect(appended.hasSuffix("Not an entry\n- [New](new.md) — hook\n"))
        let removed = MemoryIndex.removingEntries(for: "no-git-stash.md", from: appended)
        #expect(!MemoryIndex(text: removed).contains(fileName: "no-git-stash.md"))
        #expect(removed.contains("# Memory Index") && removed.contains("Not an entry"))
        #expect(MemoryIndex.appending(title: "A", fileName: "a.md", hook: "", to: "") == "# Memory Index\n\n- [A](a.md)\n")
    }
}

@Suite struct MemoryFileTests {
    @Test func extractsFieldsAndLinks() {
        let memory = MemoryFile(url: URL(filePath: "/tmp/no-git-stash.md"), text: claudeStyle, modified: .now)
        #expect(memory.type == .feedback)
        #expect(memory.links == ["other-memory", "missing"])
        #expect(memory.matches("STAGED"))
    }

    @Test func fallsBackToTopLevelType() {
        let memory = MemoryFile(url: URL(filePath: "/tmp/a.md"), text: "---\nname: a\ntype: user\n---\n", modified: .now)
        #expect(memory.type == .user)
    }
}

@Suite struct ProjectPathResolverTests {
    @Test func encodesLikeClaudeCode() {
        #expect(ProjectPathResolver.encode("/Users/me/Application Support/a.b_c") == "-Users-me-Application-Support-a-b-c")
        #expect(ProjectPathResolver.encode("/x/Tiếng") == "-x-Ti-ng")
    }

    @Test func resolvesFromSessionThenFileSystem() throws {
        let root = try TemporaryDirectory()
        let realDir = root.url.appending(path: "my-app.v2/sub dir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realPath = realDir.resolvingSymlinksInPath().path
        let id = ProjectPathResolver.encode(realPath)

        let walked = root.url.appending(path: "projects/\(id)")
        try FileManager.default.createDirectory(at: walked, withIntermediateDirectories: true)
        #expect(ProjectPathResolver().resolve(projectFolder: walked) == .init(path: realPath, exists: true))

        let deleted = root.url.appending(path: "projects/\(id)-old-thing")
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        #expect(ProjectPathResolver().resolve(projectFolder: deleted) == .init(path: realPath + "/old-thing", exists: false))

        let fromSession = root.url.appending(path: "projects2/-gone-path")
        try FileManager.default.createDirectory(at: fromSession, withIntermediateDirectories: true)
        try "{\"type\":\"summary\"}\n{\"cwd\":\"/gone/path\"}\n".write(to: fromSession.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
        #expect(ProjectPathResolver().resolve(projectFolder: fromSession) == .init(path: "/gone/path", exists: false))
    }
}

@Suite struct RepositoryTests {
    @Test func createsIndexesAndDeletesMemories() throws {
        let root = try TemporaryDirectory()
        let repository = MemoryRepository(claudeHome: root.url) { try FileManager.default.removeItem(at: $0) }
        let folder = repository.projectsDirectory.appending(path: "-p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var project = try #require(repository.loadProjects(resolver: ProjectPathResolver()).first)

        #expect(throws: MemoryError.invalidSlug("Bad Slug")) {
            try repository.createMemory(in: project, slug: "Bad Slug", title: "", description: "", type: .user, body: "")
        }
        let url = try repository.createMemory(in: project, slug: "first", title: "First", description: "d: x", type: .project, body: "See [[ghost]]")
        #expect(throws: MemoryError.alreadyExists("first.md")) {
            try repository.createMemory(in: project, slug: "first", title: "", description: "", type: .user, body: "")
        }
        try "---\nname: stray\n---\n".write(to: project.memoryDirectory.appending(path: "stray.md"), atomically: true, encoding: .utf8)

        project = try #require(repository.loadProjects(resolver: ProjectPathResolver()).first)
        let created = try #require(project.memories.first { $0.url.lastPathComponent == url.lastPathComponent })
        #expect(created.description == "d: x")
        #expect(created.type == .project)
        #expect(project.index?.contains(fileName: "first.md") == true)
        #expect(project.index?.contains(fileName: "stray.md") == false)

        let stray = try #require(project.memories.first { $0.fileName == "stray.md" })
        try repository.addToIndex(stray, in: project)
        try repository.deleteMemory(created, in: project)
        project = try #require(repository.loadProjects(resolver: ProjectPathResolver()).first)
        #expect(project.memories.map(\.fileName) == ["stray.md"])
        #expect(project.index?.entries.map(\.target) == ["stray.md"])
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
