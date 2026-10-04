import Foundation

/// One replacement in a text view's string (UTF-16 ranges), plus where the selection goes afterwards.
public struct TextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum LinePrefix: Equatable, Sendable {
    case heading(Int)
    case bullet, numbered, task, quote
}

/// Editing commands of the markdown editor, as pure functions of text and selection.
public enum MarkdownFormatting {
    /// Wraps the selection in `marker` (`**`, `*`, `` ` ``, `~~`), or unwraps it when it is already wrapped.
    public static func toggleWrap(_ text: String, selection: NSRange, marker: String) -> TextEdit {
        let string = text as NSString
        let selected = string.substring(with: selection)
        let width = (marker as NSString).length

        if selected.count >= 2 * marker.count, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: (selected as NSString).length - 2 * width))
            return TextEdit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }

        let outer = NSRange(location: selection.location - width, length: selection.length + 2 * width)
        if outer.location >= 0, NSMaxRange(outer) <= string.length,
           string.substring(with: NSRange(location: outer.location, length: width)) == marker,
           string.substring(with: NSRange(location: NSMaxRange(selection), length: width)) == marker {
            return TextEdit(range: outer, replacement: selected, selection: NSRange(location: outer.location, length: selection.length))
        }

        return TextEdit(
            range: selection,
            replacement: marker + selected + marker,
            selection: NSRange(location: selection.location + width, length: selection.length))
    }

    /// Turns the selection into `[text](url)` and selects the `url` placeholder.
    public static func link(_ text: String, selection: NSRange) -> TextEdit {
        let selected = (text as NSString).substring(with: selection)
        let label = selected.isEmpty ? "text" : selected
        let replacement = "[\(label)](url)"
        let urlStart = selection.location + (label as NSString).length + 3
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: urlStart, length: 3))
    }

    /// Fences the selection as a code block and puts the cursor on the language slot.
    public static func codeBlock(_ text: String, selection: NSRange) -> TextEdit {
        let string = text as NSString
        let selected = string.substring(with: selection)
        let atLineStart = selection.location == 0 || string.character(at: selection.location - 1) == 0x0A
        let lead = atLineStart ? "" : "\n"
        let replacement = lead + "```\n" + selected + (selected.hasSuffix("\n") || selected.isEmpty ? "" : "\n") + "```"
        return TextEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + (lead as NSString).length + 3, length: 0))
    }

    /// Applies a block prefix to every selected line, or removes it when all lines already have it.
    public static func toggleLinePrefix(_ text: String, selection: NSRange, prefix: LinePrefix) -> TextEdit {
        let (lineRange, lines) = selectedLines(text, selection: selection)
        let parsed = lines.map(BlockLine.init)
        let alreadyApplied = parsed.allSatisfy { $0.prefix == prefix }

        var number = 0
        let rewritten = parsed.map { line -> String in
            guard !alreadyApplied else { return line.indent + line.content }
            number += 1
            return line.indent + marker(for: prefix, number: number) + line.content
        }
        let replacement = rewritten.joined(separator: "\n")

        let newSelection: NSRange
        if lines.count == 1 && selection.length == 0 {
            let delta = (replacement as NSString).length - lineRange.length
            newSelection = NSRange(location: max(lineRange.location, selection.location + delta), length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: (replacement as NSString).length)
        }
        return TextEdit(range: lineRange, replacement: replacement, selection: newSelection)
    }

    /// What Return should do inside a list or quote: continue it, or end it on an empty item.
    /// Nil means "insert a plain newline".
    public static func continueBlock(_ text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let string = text as NSString
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let beforeCursor = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let line = BlockLine(beforeCursor)
        guard let prefix = line.prefix, !line.isHeading else { return nil }

        if line.content.trimmingCharacters(in: .whitespaces).isEmpty {
            let range = NSRange(location: lineStart, length: selection.location - lineStart)
            return TextEdit(range: range, replacement: "", selection: NSRange(location: lineStart, length: 0))
        }
        let next = line.indent + marker(for: prefix, number: (line.number ?? 0) + 1)
        let insertion = "\n" + next
        return TextEdit(
            range: selection,
            replacement: insertion,
            selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// Tab / Shift-Tab on list lines: nest or un-nest them. Nil when a selected line isn't a list item.
    public static func indentList(_ text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let (lineRange, lines) = selectedLines(text, selection: selection)
        let parsed = lines.map(BlockLine.init)
        guard parsed.allSatisfy({ [.bullet, .numbered, .task].contains($0.prefix) }) else { return nil }

        let rewritten = zip(lines, parsed).map { line, block -> String in
            let width = block.prefix == .numbered ? 3 : 2
            if outdent {
                return String(line.dropFirst(min(width, block.indent.count)))
            }
            return String(repeating: " ", count: width) + line
        }
        let replacement = rewritten.joined(separator: "\n")
        let delta = (replacement as NSString).length - lineRange.length
        let newSelection = lines.count == 1
            ? NSRange(location: max(lineRange.location, selection.location + delta), length: selection.length)
            : NSRange(location: lineRange.location, length: (replacement as NSString).length)
        return TextEdit(range: lineRange, replacement: replacement, selection: newSelection)
    }

    /// The full lines touched by the selection, without the final newline.
    private static func selectedLines(_ text: String, selection: NSRange) -> (NSRange, [String]) {
        let string = text as NSString
        var lineRange = string.lineRange(for: selection)
        if lineRange.length > 0, string.character(at: NSMaxRange(lineRange) - 1) == 0x0A {
            lineRange.length -= 1
        }
        return (lineRange, string.substring(with: lineRange).components(separatedBy: "\n"))
    }

    private static func marker(for prefix: LinePrefix, number: Int) -> String {
        switch prefix {
        case .heading(let level): String(repeating: "#", count: level) + " "
        case .bullet: "- "
        case .numbered: "\(number). "
        case .task: "- [ ] "
        case .quote: "> "
        }
    }
}

/// A line split into indentation, block marker and content.
private struct BlockLine {
    let indent: String
    let prefix: LinePrefix?
    let number: Int?
    let content: String

    var isHeading: Bool {
        if case .heading = prefix { true } else { false }
    }

    init(_ line: String) {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = String(line.dropFirst(indent.count))
        self.indent = indent

        if let match = rest.prefixMatch(of: #/(#{1,6}) /#) {
            prefix = .heading(match.output.1.count)
            number = nil
            content = String(rest[match.range.upperBound...])
        } else if let match = rest.prefixMatch(of: #/[-*+] \[[ xX]\] /#) {
            prefix = .task
            number = nil
            content = String(rest[match.range.upperBound...])
        } else if let match = rest.prefixMatch(of: #/[-*+] /#) {
            prefix = .bullet
            number = nil
            content = String(rest[match.range.upperBound...])
        } else if let match = rest.prefixMatch(of: #/(\d{1,9})[.)] /#) {
            prefix = .numbered
            number = Int(match.output.1)
            content = String(rest[match.range.upperBound...])
        } else if let match = rest.prefixMatch(of: #/> ?/#) {
            prefix = .quote
            number = nil
            content = String(rest[match.range.upperBound...])
        } else {
            prefix = nil
            number = nil
            content = rest
        }
    }
}
