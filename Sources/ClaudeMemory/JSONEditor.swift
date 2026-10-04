import AppKit
import MemoryCore
import SwiftUI

/// A monospaced, syntax-highlighted editor for JSON text.
struct JSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
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
        textView.backgroundColor = .textBackgroundColor
        textView.typingAttributes = Style.base
        textView.delegate = context.coordinator
        textView.string = text
        Style.highlight(textView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        Style.highlight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor

        init(_ parent: JSONEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            Style.highlight(textView)
        }
    }

    @MainActor
    private enum Style {
        static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        static func color(for kind: JSONSpan.Kind) -> NSColor {
            switch kind {
            case .key: .systemBlue
            case .string: .systemGreen
            case .number: .systemOrange
            case .literal: .systemPurple
            case .punctuation: .secondaryLabelColor
            }
        }

        static func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            for span in JSONHighlighter.spans(in: storage.string) {
                storage.addAttribute(.foregroundColor, value: color(for: span.kind), range: span.range)
            }
            storage.endEditing()
        }
    }
}
