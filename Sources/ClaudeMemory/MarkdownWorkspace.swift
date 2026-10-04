import AppKit
import SwiftUI
import WebKit

/// Opens a file in the detail column (provided by ContentView).
struct OpenDocumentAction {
    let handler: (DocumentRef) -> Void

    func callAsFunction(_ document: DocumentRef) {
        handler(document)
    }
}

extension EnvironmentValues {
    @Entry var openDocument = OpenDocumentAction { _ in }
}

/// Connects the format bar, the editor and the preview of one workspace without
/// routing every keystroke or scroll tick through SwiftUI state.
@MainActor
final class EditorLink {
    weak var textView: MarkdownTextView?
    weak var preview: MarkdownPreview.Coordinator?
    /// The editor's top visible line, so a preview that appears later starts in the same place.
    var topLine = 0

    func editorScrolled(to line: Int) {
        guard line != topLine else { return }
        topLine = line
        preview?.scroll(to: line)
    }
}

/// Markdown editing area with three layouts: edit, split (editor + preview), preview.
struct MarkdownWorkspace: View {
    enum Layout: String, CaseIterable {
        case edit, split, preview

        var title: String {
            switch self {
            case .edit: "Edit"
            case .split: "Split"
            case .preview: "Preview"
            }
        }

        var symbol: String {
            switch self {
            case .edit: "square.and.pencil"
            case .split: "rectangle.split.2x1"
            case .preview: "eye"
            }
        }
    }

    @Binding var text: String
    /// The file the text belongs to; relative links in the preview resolve against it.
    let fileURL: URL
    /// Slugs offered after `[[`.
    let completionNames: [String]
    /// Every name a wikilink may resolve to (slugs and frontmatter names).
    let knownNames: Set<String>
    let openWikiLink: (String) -> Void

    @AppStorage("markdownLayout") private var layout = Layout.split
    @State private var link = EditorLink()
    @Environment(\.openDocument) private var openDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            FormatBar(link: link, layout: layout)
            Divider()
            switch layout {
            case .edit:
                editor
            case .split:
                HSplitView {
                    editor.frame(minWidth: 240, maxWidth: .infinity)
                    preview.frame(minWidth: 240, maxWidth: .infinity)
                }
            case .preview:
                preview
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Layout", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .help("Edit, split, or preview only")
            }
        }
    }

    private var editor: some View {
        MarkdownEditor(text: $text, completionNames: completionNames, knownNames: knownNames, link: link,
                       openWikiLink: openWikiLink, openURL: openHref)
    }

    private var preview: some View {
        MarkdownPreview(text: text, knownNames: knownNames, link: link, openWikiLink: openWikiLink, openHref: openHref)
    }

    /// Web links open in the browser; relative `.md` links open in the app.
    private func openHref(_ href: String) {
        if let url = URL(string: href), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let path = href.removingPercentEncoding ?? href
        let target = path.hasPrefix("/")
            ? URL(filePath: path)
            : URL(filePath: path, relativeTo: fileURL.deletingLastPathComponent()).absoluteURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        if target.pathExtension.lowercased() == "md" {
            openDocument(model.memory(at: target) != nil ? .memory(target) : .text(target))
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

private struct FormatBar: View {
    let link: EditorLink
    let layout: MarkdownWorkspace.Layout

    private let groups: [[(EditorCommand, String)]] = [
        [(.heading1, "1.square"), (.heading2, "2.square"), (.heading3, "3.square")],
        [(.bold, "bold"), (.italic, "italic"), (.strikethrough, "strikethrough"), (.inlineCode, "chevron.left.forwardslash.chevron.right")],
        [(.link, "link"), (.codeBlock, "curlybraces.square")],
        [(.bullet, "list.bullet"), (.numbered, "list.number"), (.task, "checklist"), (.quote, "text.quote")],
    ]

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 {
                    Spacer().frame(width: Spacing.xs)
                }
                ForEach(groups[index], id: \.1) { command, symbol in
                    Button {
                        link.textView?.window?.makeFirstResponder(link.textView)
                        link.textView?.perform(command)
                    } label: {
                        Image(systemName: symbol).frame(width: Spacing.l, height: Spacing.m + Spacing.xxs)
                    }
                    .help("\(command.title) (\(command.shortcutLabel))")
                    .disabled(layout == .preview)
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs)
    }
}

// MARK: - Editor

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let completionNames: [String]
    let knownNames: Set<String>
    let link: EditorLink
    let openWikiLink: (String) -> Void
    let openURL: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        textView.delegate = context.coordinator
        textView.knownNames = knownNames
        textView.setText(text)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView, textView: textView)

        link.textView = textView
        configure(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        link.textView = textView
        configure(textView)
        if textView.string != text {
            textView.setText(text)
        }
    }

    private func configure(_ textView: MarkdownTextView) {
        textView.completionNames = completionNames
        textView.knownNames = knownNames
        textView.onOpenWikiLink = openWikiLink
        textView.onOpenURL = openURL
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        private weak var textView: MarkdownTextView?
        private weak var scrollView: NSScrollView?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func observeScrolling(of scrollView: NSScrollView, textView: MarkdownTextView) {
            self.scrollView = scrollView
            self.textView = textView
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let textView, let scrollView else { return }
            parent.link.editorScrolled(to: Self.topLine(of: textView, in: scrollView))
        }

        /// Zero-based line at the top of the visible area.
        private static func topLine(of textView: NSTextView, in scrollView: NSScrollView) -> Int {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 0 }
            var point = scrollView.contentView.bounds.origin
            point.y -= textView.textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            let prefix = (textView.string as NSString).substring(to: min(character, (textView.string as NSString).length))
            return prefix.utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
    }
}

// MARK: - Preview

struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let knownNames: Set<String>
    let link: EditorLink
    let openWikiLink: (String) -> Void
    let openHref: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "preview")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        link.preview = context.coordinator
        if let page = Bundle.module.url(forResource: "preview", withExtension: "html", subdirectory: "Preview") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        link.preview = context.coordinator
        context.coordinator.render()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "preview")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MarkdownPreview
        weak var webView: WKWebView?
        private var isReady = false
        private var rendered: (String, Set<String>)?
        private var pendingRender: Task<Void, Never>?

        init(_ parent: MarkdownPreview) {
            self.parent = parent
        }

        /// Re-renders when the text or names changed, coalescing bursts of typing.
        func render() {
            guard isReady, rendered.map({ $0 != (parent.text, parent.knownNames) }) ?? true else { return }
            pendingRender?.cancel()
            pendingRender = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                let text = parent.text, names = parent.knownNames
                rendered = (text, names)
                call("render", [text, Array(names)])
            }
        }

        func scroll(to line: Int) {
            guard isReady else { return }
            call("scrollToLine", [line])
        }

        private func call(_ function: String, _ arguments: [Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("\(function)(...\(json))")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] != nil {
                isReady = true
                let text = parent.text, names = parent.knownNames
                rendered = (text, names)
                call("render", [text, Array(names)])
                scroll(to: parent.link.topLine)
            } else if let target = body["wiki"] as? String {
                parent.openWikiLink(target)
            } else if let href = body["href"] as? String {
                parent.openHref(href)
            }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
