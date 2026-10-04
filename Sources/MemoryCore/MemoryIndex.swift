import Foundation

/// `MEMORY.md`: one `- [Title](file.md) — hook` line per memory, mixed with
/// whatever headings and blank lines Claude or the user put there.
public struct MemoryIndex: Hashable, Sendable {
    public static let fileName = "MEMORY.md"

    public struct Entry: Hashable, Sendable {
        /// Zero-based line number in the index text.
        public let line: Int
        public let title: String
        /// The link target normalized to a file name relative to the memory directory.
        public let target: String
        public let hook: String
    }

    /// Claude Code loads only this many lines or bytes of the index into each session.
    public static let loadedLineLimit = 200
    public static let loadedByteLimit = 25_000

    /// A message when `text` is longer than what Claude Code loads, nil otherwise.
    public static func truncationWarning(for text: String) -> String? {
        let lines = text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        let overLines = lines > loadedLineLimit
        let overBytes = text.utf8.count > loadedByteLimit
        guard overLines || overBytes else { return nil }
        let reason = overLines ? "\(lines) lines (limit \(loadedLineLimit))" : "\(text.utf8.count / 1000) KB (limit \(loadedByteLimit / 1000) KB)"
        return "MEMORY.md is \(reason). Claude Code ignores everything after the limit."
    }

    public let text: String
    public let entries: [Entry]

    public init(text: String) {
        self.text = text
        entries = text.components(separatedBy: "\n").enumerated().compactMap { number, line in
            guard let match = line.wholeMatch(of: Self.entryPattern) else { return nil }
            return Entry(
                line: number,
                title: String(match.output.1),
                target: Self.normalize(String(match.output.2)),
                hook: match.output.3.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        }
    }

    public func contains(fileName: String) -> Bool {
        entries.contains { $0.target == fileName }
    }

    public static func appending(title: String, fileName: String, hook: String, to text: String) -> String {
        let link = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let flatHook = hook.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let line = "- [\(title)](\(link))" + (flatHook.isEmpty ? "" : " — \(flatHook)")
        if text.isEmpty {
            return "# Memory Index\n\n\(line)\n"
        }
        return text + (text.hasSuffix("\n") ? "" : "\n") + line + "\n"
    }

    /// The raw lines of `text` that list `fileName`.
    public static func lines(for fileName: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return MemoryIndex(text: text).entries.filter { $0.target == fileName }.map { lines[$0.line] }
    }

    public static func appending(lines: [String], to text: String) -> String {
        let block = lines.joined(separator: "\n") + "\n"
        if text.isEmpty {
            return "# Memory Index\n\n" + block
        }
        return text + (text.hasSuffix("\n") ? "" : "\n") + block
    }

    public static func removingEntries(for fileName: String, from text: String) -> String {
        let index = MemoryIndex(text: text)
        let doomed = Set(index.entries.filter { $0.target == fileName }.map(\.line))
        return text.components(separatedBy: "\n").enumerated()
            .filter { !doomed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    private static var entryPattern: Regex<(Substring, Substring, Substring, Substring?)> {
        /\s*[-*+]\s+\[(.+?)\]\(([^)\s]+)\)\s*(?:[—–-]+\s*(.*))?/
    }

    private static func normalize(_ target: String) -> String {
        var target = target.removingPercentEncoding ?? target
        if target.hasPrefix("./") {
            target.removeFirst(2)
        }
        return target
    }
}
