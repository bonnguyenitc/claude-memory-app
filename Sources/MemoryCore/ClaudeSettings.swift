import Foundation

/// Reads and edits the text of Claude Code's `settings.json` without reformatting it.
public enum ClaudeSettings {
    public static let fileName = "settings.json"

    /// Top-level key that turns Claude Code's auto memory on or off.
    public static let autoMemoryKey = "autoMemoryEnabled"

    /// A message describing why the text is not a JSON object, or nil when it is valid.
    public static func validationError(in text: String) -> String? {
        if text.allSatisfy(\.isWhitespace) { return nil }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
            return value is [String: Any] ? nil : "settings.json must be a JSON object."
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return message ?? error.localizedDescription
        }
    }

    /// The text re-indented with two spaces, keeping key order, number spellings and string contents as written.
    /// Returns nil when the text is not valid JSON.
    public static func formatted(_ text: String) -> String? {
        guard validationError(in: text) == nil, !text.allSatisfy(\.isWhitespace) else { return nil }
        var output = ""
        var depth = 0
        var characters = text.makeIterator()
        var pending = characters.next()

        func newline() { output += "\n" + String(repeating: "  ", count: depth) }
        func skipWhitespace() {
            while let character = pending, character.isWhitespace { pending = characters.next() }
        }

        while let character = pending {
            pending = characters.next()
            switch character {
            case "\"":
                output.append(character)
                var escaped = false
                while let next = pending {
                    pending = characters.next()
                    output.append(next)
                    if escaped { escaped = false } else if next == "\\" { escaped = true } else if next == "\"" { break }
                }
            case "{", "[":
                output.append(character)
                skipWhitespace()
                if let next = pending, next == (character == "{" ? "}" : "]") {
                    output.append(next)
                    pending = characters.next()
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output += ": "
            default:
                if !character.isWhitespace { output.append(character) }
            }
        }
        return output + "\n"
    }

    /// The top-level boolean stored under `key`, or nil when it is absent or not a boolean.
    public static func bool(_ key: String, in text: String) -> Bool? {
        guard let object = object(in: text) else { return nil }
        return (object[key] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
    }

    /// Sets a top-level boolean, editing only that value or inserting one line after the opening brace.
    /// Returns nil when the text is not a valid JSON object.
    public static func setting(_ key: String, to value: Bool, in text: String) -> String? {
        if text.allSatisfy(\.isWhitespace) {
            return "{\n  \"\(key)\": \(value)\n}\n"
        }
        guard let object = object(in: text) else { return nil }

        if object[key] != nil {
            let pattern = try! Regex("(\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*)(true|false)")
            guard let match = text.firstMatch(of: pattern), let range = match.output[2].range else { return nil }
            var updated = text
            updated.replaceSubrange(range, with: String(value))
            return updated
        }

        guard let brace = text.firstIndex(of: "{") else { return nil }
        let after = text.index(after: brace)
        let separator = object.isEmpty ? "" : ","
        var updated = text
        updated.insert(contentsOf: "\n  \"\(key)\": \(value)\(separator)", at: after)
        return updated
    }

    /// Top-level key that moves the folder auto memory is stored in.
    public static let autoMemoryDirectoryKey = "autoMemoryDirectory"

    /// A message when `path` is not something Claude Code accepts as a memory directory, nil when it is fine or empty.
    public static func memoryDirectoryError(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") || path.hasPrefix("~/") ? nil : "Use an absolute path or one starting with ~/."
    }

    /// The top-level string stored under `key`, or nil when it is absent or not a string.
    public static func string(_ key: String, in text: String) -> String? {
        object(in: text)?[key] as? String
    }

    /// Sets a top-level string, or removes the key when `value` is empty. Returns nil when the text is not a valid JSON object.
    public static func setting(_ key: String, toString value: String, in text: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let member = "\"\(escapedKey)\"\\s*:\\s*\"(?:[^\"\\\\]|\\\\.)*\""

        if value.isEmpty {
            guard let object = object(in: text) else { return nil }
            guard object[key] != nil else { return text }
            for pattern in ["\\s*,\\s*\(member)", "\(member)\\s*,?\\s*"] {
                let updated = text.replacing(try! Regex(pattern), with: "", maxReplacements: 1)
                if updated != text, validationError(in: updated) == nil, Self.object(in: updated)?[key] == nil {
                    return updated
                }
            }
            return nil
        }

        guard let literal = try? JSONEncoder().encode(value), let json = String(data: literal, encoding: .utf8) else { return nil }
        if text.allSatisfy(\.isWhitespace) {
            return "{\n  \"\(key)\": \(json)\n}\n"
        }
        guard let object = object(in: text) else { return nil }
        if object[key] != nil {
            guard let match = text.firstMatch(of: try! Regex("(\(member))")), let range = match.output[0].range else { return nil }
            var updated = text
            updated.replaceSubrange(range, with: "\"\(key)\": \(json)")
            return updated
        }
        guard let brace = text.firstIndex(of: "{") else { return nil }
        var updated = text
        updated.insert(contentsOf: "\n  \"\(key)\": \(json)\(object.isEmpty ? "" : ",")", at: text.index(after: brace))
        return updated
    }

    private static func object(in text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}
