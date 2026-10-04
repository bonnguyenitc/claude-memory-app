import Foundation

/// A markdown file split into YAML frontmatter lines and a body.
///
/// Edits rewrite only the lines they touch, so keys this app does not know
/// about (`originSessionId`, `node_type`, …) and their formatting survive a save.
/// Only the flat `key: value` and one-level nested `parent:\n  key: value`
/// shapes that Claude Code writes are supported.
public struct MarkdownDocument: Equatable, Sendable {
    public private(set) var frontmatter: [String]?
    public var body: String

    public init(parsing text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
            frontmatter = nil
            body = lines.joined(separator: "\n")
            return
        }
        frontmatter = Array(lines[1..<close])
        body = lines[(close + 1)...].joined(separator: "\n")
    }

    public func serialized() -> String {
        guard let frontmatter else { return body }
        return (["---"] + frontmatter + ["---"]).joined(separator: "\n") + "\n" + body
    }

    /// Reads a scalar at `path`, e.g. `["name"]` or `["metadata", "type"]`.
    public func value(at path: [String]) -> String? {
        guard let frontmatter, let index = Self.locate(path, in: frontmatter) else { return nil }
        let line = Self.keyLine(frontmatter[index])!
        let continuation = frontmatter[(index + 1)..<Self.blockEnd(after: index, in: frontmatter)]
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return Self.scalar(line.value, continuation: continuation)
    }

    /// Writes a scalar at `path`, replacing the old value (including any
    /// multi-line continuation) or inserting the key if it is missing.
    public mutating func setValue(_ value: String, at path: [String]) {
        precondition((1...2).contains(path.count), "Only one level of nesting is supported")
        var lines = frontmatter ?? []
        let rendered = Self.yamlScalar(value)

        if let index = Self.locate(path, in: lines) {
            let indent = Self.keyLine(lines[index])!.indent
            let replacement = String(repeating: " ", count: indent) + path.last! + ": " + rendered
            lines.replaceSubrange(index..<Self.blockEnd(after: index, in: lines), with: [replacement])
        } else if path.count == 1 {
            lines.append(path[0] + ": " + rendered)
        } else if let parent = Self.locate([path[0]], in: lines) {
            let end = Self.blockEnd(after: parent, in: lines)
            let childIndent = lines[(parent + 1)..<end].lazy.compactMap(Self.keyLine).first?.indent ?? 2
            lines.insert(String(repeating: " ", count: childIndent) + path[1] + ": " + rendered, at: end)
        } else {
            lines.append(path[0] + ":")
            lines.append("  " + path[1] + ": " + rendered)
        }
        frontmatter = lines
    }

    // MARK: - Line parsing

    struct KeyLine {
        let indent: Int
        let key: String
        let value: String
    }

    static func keyLine(_ line: String) -> KeyLine? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let key = rest[..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let afterColon = rest[rest.index(after: colon)...]
        guard afterColon.isEmpty || afterColon.first == " " else { return nil }
        return KeyLine(indent: indent, key: String(key), value: afterColon.trimmingCharacters(in: .whitespaces))
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    /// Index one past the last line that belongs to the key at `index`
    /// (its nested children or multi-line continuation).
    static func blockEnd(after index: Int, in lines: [String]) -> Int {
        let base = indent(of: lines[index])
        var end = index + 1
        while end < lines.count, isBlank(lines[end]) || indent(of: lines[end]) > base {
            end += 1
        }
        // Trailing blank lines separate blocks; they don't belong to this one.
        while end > index + 1, isBlank(lines[end - 1]) {
            end -= 1
        }
        return end
    }

    static func locate(_ path: [String], in lines: [String]) -> Int? {
        guard let first = path.first else { return nil }
        guard let top = lines.indices.first(where: {
            let line = keyLine(lines[$0])
            return line?.indent == 0 && line?.key == first
        }) else { return nil }
        guard path.count == 2 else { return top }

        let children = (top + 1)..<blockEnd(after: top, in: lines)
        guard let childIndent = children.lazy.compactMap({ keyLine(lines[$0]) }).first?.indent else { return nil }
        return children.first {
            let line = keyLine(lines[$0])
            return line?.indent == childIndent && line?.key == path[1]
        }
    }

    // MARK: - Scalars

    static func scalar(_ raw: String, continuation: [String]) -> String {
        if raw.hasPrefix("|") {
            return continuation.joined(separator: "\n")
        }
        if raw.hasPrefix(">") {
            return continuation.joined(separator: " ")
        }
        if raw.hasPrefix("\""), raw.count >= 2, raw.hasSuffix("\"") {
            return unescapeDoubleQuoted(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("'"), raw.count >= 2, raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return ([raw] + continuation).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func unescapeDoubleQuoted(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(escaped)
            }
        }
        return result
    }

    static func yamlScalar(_ value: String) -> String {
        let reservedStarts: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        let reservedWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]
        let needsQuotes = value.isEmpty
            || value != value.trimmingCharacters(in: .whitespaces)
            || reservedStarts.contains(value.first!)
            || reservedWords.contains(value.lowercased())
            || Double(value) != nil
            || value.contains(": ")
            || value.contains(" #")
            || value.hasSuffix(":")
            || value.contains(where: { $0 == "\n" || $0 == "\t" })
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }
}
