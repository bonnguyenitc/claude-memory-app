import Foundation
import Markdown

public struct HighlightSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case strong, emphasis, strikethrough
        case inlineCode, codeBlock
        case link, linkDestination
        case wikiLink(target: String)
        case blockQuote, listMarker, taskMarker, thematicBreak, html
        case frontmatter, frontmatterKey
        /// Markup punctuation (`**`, `#`, `[`…) drawn dimmer than the text it wraps.
        case syntax
    }

    public let kind: Kind
    /// UTF-16 range, ready for NSTextStorage.
    public let range: NSRange
}

/// Finds the ranges to color in a markdown source. Block and inline structure
/// comes from swift-markdown (CommonMark + GFM); YAML frontmatter and
/// `[[wikilinks]]`, which CommonMark doesn't know, are found separately.
/// Spans are ordered so that later ones should be applied on top of earlier ones.
public enum MarkdownHighlighter {
    public static func spans(in text: String) -> [HighlightSpan] {
        let source = SourceMap(text)
        var spans: [HighlightSpan] = []

        let lines = text.components(separatedBy: "\n")
        var bodyStartLine = 0
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            bodyStartLine = close + 1
            spans.append(HighlightSpan(kind: .frontmatter, range: source.range(lines: 0..<bodyStartLine)))
            for number in 1..<close {
                if let key = MarkdownDocument.keyLine(lines[number]) {
                    let start = source.utf8Offset(line: number) + key.indent
                    spans.append(HighlightSpan(kind: .frontmatterKey, range: source.nsRange(start, start + key.key.utf8.count + 1)))
                }
            }
        }

        let body = lines[bodyStartLine...].joined(separator: "\n")
        var walker = Walker(source: source, lineOffset: bodyStartLine)
        walker.visit(Document(parsing: body))
        spans += walker.spans

        let code = walker.spans.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }.map(\.range)
        let bodyStart = source.utf16Offset(line: bodyStartLine)
        for match in body.matches(of: /\[\[([^\[\]\n]+)\]\]/) {
            let range = NSRange(match.range, in: body)
            let absolute = NSRange(location: range.location + bodyStart, length: range.length)
            guard !code.contains(where: { NSIntersectionRange($0, absolute).length > 0 }) else { continue }
            let target = String(match.output.1).split(separator: "|").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            spans.append(HighlightSpan(kind: .wikiLink(target: target), range: absolute))
            spans.append(HighlightSpan(kind: .syntax, range: NSRange(location: absolute.location, length: 2)))
            spans.append(HighlightSpan(kind: .syntax, range: NSRange(location: NSMaxRange(absolute) - 2, length: 2)))
        }
        return spans
    }

    private struct Walker: MarkupWalker {
        let source: SourceMap
        let lineOffset: Int
        var spans: [HighlightSpan] = []

        init(source: SourceMap, lineOffset: Int) {
            self.source = source
            self.lineOffset = lineOffset
        }

        /// Absolute UTF-8 offsets of a node, or nil when cmark gave it no range.
        private func bounds(_ markup: Markup) -> (Int, Int)? {
            guard let range = markup.range else { return nil }
            return (offset(range.lowerBound), offset(range.upperBound))
        }

        private func offset(_ location: SourceLocation) -> Int {
            source.utf8Offset(line: location.line - 1 + lineOffset) + location.column - 1
        }

        private mutating func add(_ kind: HighlightSpan.Kind, _ start: Int, _ end: Int) {
            guard end > start else { return }
            spans.append(HighlightSpan(kind: kind, range: source.nsRange(start, end)))
        }

        /// Colors a node and dims the punctuation between its edges and its children.
        private mutating func wrap(_ markup: Markup, as kind: HighlightSpan.Kind, closingKind: HighlightSpan.Kind = .syntax) {
            guard let (start, end) = bounds(markup) else { return descendInto(markup) }
            add(kind, start, end)
            descendInto(markup)
            let children = Array(markup.children).compactMap(bounds)
            if let first = children.first, let last = children.last {
                add(.syntax, start, first.0)
                add(closingKind, last.1, end)
            }
        }

        mutating func visitHeading(_ heading: Heading) {
            guard let (start, end) = bounds(heading) else { return }
            add(.heading(level: heading.level), start, end)
            descendInto(heading)
            if let first = Array(heading.children).compactMap(bounds).first, first.0 > start {
                add(.syntax, start, first.0)
            }
        }

        mutating func visitStrong(_ strong: Strong) { wrap(strong, as: .strong) }
        mutating func visitEmphasis(_ emphasis: Emphasis) { wrap(emphasis, as: .emphasis) }
        mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap(strikethrough, as: .strikethrough) }
        mutating func visitLink(_ link: Link) { wrap(link, as: .link, closingKind: .linkDestination) }
        mutating func visitImage(_ image: Image) { wrap(image, as: .link, closingKind: .linkDestination) }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            if let (start, end) = bounds(inlineCode) { add(.inlineCode, start, end) }
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            if let (start, end) = bounds(codeBlock) { add(.codeBlock, start, end) }
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            if let (start, end) = bounds(html) { add(.html, start, end) }
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            if let (start, end) = bounds(inlineHTML) { add(.html, start, end) }
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            if let (start, end) = bounds(thematicBreak) { add(.thematicBreak, start, end) }
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            if let (start, end) = bounds(blockQuote) { add(.blockQuote, start, end) }
            descendInto(blockQuote)
        }

        mutating func visitListItem(_ listItem: ListItem) {
            if let (start, _) = bounds(listItem), let first = Array(listItem.children).compactMap(bounds).first,
               first.0 > start, source.line(ofUTF8: first.0) == source.line(ofUTF8: start) {
                add(listItem.checkbox == nil ? .listMarker : .taskMarker, start, first.0)
            }
            descendInto(listItem)
        }
    }
}

/// Converts between line numbers, UTF-8 offsets (what cmark reports) and UTF-16 offsets (what AppKit uses).
struct SourceMap {
    private let lineStartsUTF8: [Int]
    private let lineStartsUTF16: [Int]
    /// UTF-16 offset for every UTF-8 offset, including the end of the text.
    private let utf16ForUTF8: [Int]

    init(_ text: String) {
        var utf16ForUTF8: [Int] = []
        utf16ForUTF8.reserveCapacity(text.utf8.count + 1)
        var lineStartsUTF8 = [0]
        var lineStartsUTF16 = [0]
        var utf16 = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            for _ in 0..<width {
                utf16ForUTF8.append(utf16)
            }
            utf16 += UTF16.width(scalar)
            if scalar == "\n" {
                lineStartsUTF8.append(utf16ForUTF8.count)
                lineStartsUTF16.append(utf16)
            }
        }
        utf16ForUTF8.append(utf16)
        self.utf16ForUTF8 = utf16ForUTF8
        self.lineStartsUTF8 = lineStartsUTF8
        self.lineStartsUTF16 = lineStartsUTF16
    }

    /// Zero-based line → UTF-8 offset of its first character (clamped to the end of the text).
    func utf8Offset(line: Int) -> Int {
        line < lineStartsUTF8.count ? lineStartsUTF8[max(line, 0)] : utf16ForUTF8.count - 1
    }

    func utf16Offset(line: Int) -> Int {
        line < lineStartsUTF16.count ? lineStartsUTF16[max(line, 0)] : utf16ForUTF8.last!
    }

    func line(ofUTF8 offset: Int) -> Int {
        (lineStartsUTF8.lastIndex { $0 <= offset }) ?? 0
    }

    func nsRange(_ startUTF8: Int, _ endUTF8: Int) -> NSRange {
        let clamp = { (offset: Int) in self.utf16ForUTF8[min(max(offset, 0), self.utf16ForUTF8.count - 1)] }
        let start = clamp(startUTF8)
        return NSRange(location: start, length: max(clamp(endUTF8) - start, 0))
    }

    /// The UTF-16 range covering whole lines, including the newline after the last one.
    func range(lines: Range<Int>) -> NSRange {
        let start = utf16Offset(line: lines.lowerBound)
        return NSRange(location: start, length: utf16Offset(line: lines.upperBound) - start)
    }
}
