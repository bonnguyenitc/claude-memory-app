import AppKit
import MemoryCore

enum EditorCommand: CaseIterable {
    case heading1, heading2, heading3
    case bold, italic, strikethrough, inlineCode
    case link, codeBlock
    case bullet, numbered, task, quote

    var title: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Code"
        case .link: "Link"
        case .codeBlock: "Code block"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .task: "Checklist"
        case .quote: "Quote"
        }
    }

    /// Key equivalent: unshifted character plus whether Shift is held (Command is implied).
    var shortcut: (key: String, shift: Bool) {
        switch self {
        case .heading1: ("1", false)
        case .heading2: ("2", false)
        case .heading3: ("3", false)
        case .bold: ("b", false)
        case .italic: ("i", false)
        case .strikethrough: ("x", true)
        case .inlineCode: ("e", false)
        case .link: ("k", false)
        case .codeBlock: ("c", true)
        case .bullet: ("8", true)
        case .numbered: ("7", true)
        case .task: ("9", true)
        case .quote: (".", true)
        }
    }

    var shortcutLabel: String {
        "\(shortcut.shift ? "⇧" : "")⌘\(shortcut.key.uppercased())"
    }

    func edit(_ text: String, selection: NSRange) -> TextEdit {
        switch self {
        case .heading1: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .heading(1))
        case .heading2: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .heading(2))
        case .heading3: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .heading(3))
        case .bold: MarkdownFormatting.toggleWrap(text, selection: selection, marker: "**")
        case .italic: MarkdownFormatting.toggleWrap(text, selection: selection, marker: "*")
        case .strikethrough: MarkdownFormatting.toggleWrap(text, selection: selection, marker: "~~")
        case .inlineCode: MarkdownFormatting.toggleWrap(text, selection: selection, marker: "`")
        case .link: MarkdownFormatting.link(text, selection: selection)
        case .codeBlock: MarkdownFormatting.codeBlock(text, selection: selection)
        case .bullet: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .bullet)
        case .numbered: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .numbered)
        case .task: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .task)
        case .quote: MarkdownFormatting.toggleLinePrefix(text, selection: selection, prefix: .quote)
        }
    }
}

/// Plain-text markdown editor: live highlighting, formatting shortcuts, list
/// continuation, `[[` completion and Cmd-click on links.
final class MarkdownTextView: NSTextView {
    /// Memory names offered after `[[` (slugs).
    var completionNames: [String] = []
    /// Names that resolve to a memory (slugs and frontmatter names), for coloring wikilinks.
    var knownNames: Set<String> = [] {
        didSet { if knownNames != oldValue { rehighlight() } }
    }
    var onOpenWikiLink: ((String) -> Void)?
    var onOpenURL: ((String) -> Void)?

    private var spans: [HighlightSpan] = []

    static func make() -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = Style.base
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        return textView
    }

    func setText(_ text: String) {
        let selection = selectedRange()
        string = text
        let length = (text as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        rehighlight()
    }

    func perform(_ command: EditorCommand) {
        apply(command.edit(string, selection: selectedRange()), actionName: command.title)
    }

    /// Replaces text through the undo-aware path so every command is one undo step.
    private func apply(_ edit: TextEdit, actionName: String) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        undoManager?.setActionName(actionName)
    }

    // MARK: - Highlighting

    override func didChangeText() {
        rehighlight()
        super.didChangeText()
        offerWikiCompletionIfNeeded()
    }

    func rehighlight() {
        guard let storage = textStorage else { return }
        spans = MarkdownHighlighter.spans(in: string)
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(Style.base, range: full)
        for span in spans where NSMaxRange(span.range) <= storage.length {
            Style.apply(span.kind, to: span.range, in: storage, knownNames: knownNames)
        }
        storage.endEditing()
        typingAttributes = Style.base
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              let key = event.characters(byApplyingModifiers: [])?.lowercased(),
              let command = EditorCommand.allCases.first(where: { $0.shortcut == (key, flags.contains(.shift)) })
        else { return super.performKeyEquivalent(with: event) }
        perform(command)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if let edit = MarkdownFormatting.continueBlock(string, selection: selectedRange()) {
            apply(edit, actionName: "New line")
        } else {
            super.insertNewline(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if let edit = MarkdownFormatting.indentList(string, selection: selectedRange(), outdent: false) {
            apply(edit, actionName: "Indent")
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if let edit = MarkdownFormatting.indentList(string, selection: selectedRange(), outdent: true) {
            apply(edit, actionName: "Outdent")
        } else {
            super.insertBacktab(sender)
        }
    }

    // MARK: - Cmd-click

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.mouseDown(with: event) }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let hit = spans.last { NSLocationInRange(index, $0.range) && ($0.kind.isWikiLink || $0.kind == .link) }
        switch hit?.kind {
        case .wikiLink(let target):
            onOpenWikiLink?(target)
        case .link:
            let source = (string as NSString).substring(with: hit!.range)
            if let destination = source.firstMatch(of: /\]\(\s*<?([^)\s>]+)/)?.output.1 {
                onOpenURL?(String(destination))
            }
        default:
            super.mouseDown(with: event)
        }
    }

    // MARK: - [[ completion

    /// The partial name after an unclosed `[[` on the cursor's line.
    override var rangeForUserCompletion: NSRange {
        let cursor = selectedRange()
        guard cursor.length == 0 else { return NSRange(location: NSNotFound, length: 0) }
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: cursor.location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: cursor.location - lineStart))
        guard let open = before.range(of: "[[", options: .backwards),
              !before[open.upperBound...].contains("]") else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let start = lineStart + (before[..<open.upperBound] as Substring).utf16.count
        return NSRange(location: start, length: cursor.location - start)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let partial = (string as NSString).substring(with: charRange)
        let matches = completionNames
            .filter { partial.isEmpty || $0.localizedStandardContains(partial) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.hasPrefix(partial), rhsPrefix = rhs.hasPrefix(partial)
                return lhsPrefix != rhsPrefix ? lhsPrefix : lhs < rhs
            }
        index.pointee = matches.isEmpty ? -1 : 0
        return matches
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, movement != NSTextMovement.cancel.rawValue else { return }
        let cursor = selectedRange().location
        let text = string as NSString
        let closed = cursor + 2 <= text.length && text.substring(with: NSRange(location: cursor, length: 2)) == "]]"
        if closed {
            setSelectedRange(NSRange(location: cursor + 2, length: 0))
        } else {
            insertText("]]", replacementRange: selectedRange())
        }
    }

    private func offerWikiCompletionIfNeeded() {
        let cursor = selectedRange()
        guard !completionNames.isEmpty, cursor.length == 0, cursor.location >= 2,
              (string as NSString).substring(with: NSRange(location: cursor.location - 2, length: 2)) == "[[" else { return }
        DispatchQueue.main.async { [weak self] in
            self?.complete(nil)
        }
    }
}

private extension HighlightSpan.Kind {
    var isWikiLink: Bool {
        if case .wikiLink = self { true } else { false }
    }
}

/// Text attributes for each kind of highlight span.
@MainActor
private enum Style {
    static let fontSize: CGFloat = 13
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    static let base: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }()

    static func apply(_ kind: HighlightSpan.Kind, to range: NSRange, in storage: NSTextStorage, knownNames: Set<String>) {
        switch kind {
        case .heading(let level):
            let extra: CGFloat = [6, 4, 2][safe: level - 1] ?? 0
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize + extra, weight: .bold), range: range)
        case .strong:
            addTrait(.boldFontMask, range, storage)
        case .emphasis:
            addTrait(.italicFontMask, range, storage)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode:
            storage.addAttributes([.foregroundColor: NSColor.systemPink, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: range)
        case .codeBlock:
            storage.addAttributes([.foregroundColor: NSColor.systemTeal, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)], range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        case .linkDestination:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .wikiLink(let target):
            let known = knownNames.contains(target)
            storage.addAttributes([
                .foregroundColor: known ? NSColor.systemPurple : NSColor.systemRed,
                .underlineStyle: (known ? NSUnderlineStyle.single : [.single, .patternDash]).rawValue,
                .toolTip: known ? "⌘-click to open \(target)" : "No memory “\(target)” yet",
            ], range: range)
        case .blockQuote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            addTrait(.italicFontMask, range, storage)
        case .listMarker, .taskMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
        case .thematicBreak, .syntax:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .html:
            storage.addAttribute(.foregroundColor, value: NSColor.systemGray, range: range)
        case .frontmatter:
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15)], range: range)
        case .frontmatterKey:
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
        }
    }

    /// Adds bold/italic on top of whatever font each part of the range already has (e.g. a heading's size).
    private static func addTrait(_ trait: NSFontTraitMask, _ range: NSRange, _ storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let current = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: trait), range: subrange)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
