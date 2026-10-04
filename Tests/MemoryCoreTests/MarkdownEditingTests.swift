import Foundation
import Testing
@testable import MemoryCore

private func substrings(_ text: String, _ kind: HighlightSpan.Kind) -> [String] {
    MarkdownHighlighter.spans(in: text).filter { $0.kind == kind }.map { (text as NSString).substring(with: $0.range) }
}

private func apply(_ edit: TextEdit, to text: String) -> (String, String) {
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    return (result, (result as NSString).substring(with: edit.selection))
}

@Suite struct MarkdownHighlighterTests {
    let text = """
    ---
    name: x
    metadata:
      type: user
    ---

    # Tiêu đề

    chữ **đậm** và `[[không link]]` xem [[ghi-chú|bí danh]] và [web](https://a.b)
    - [ ] việc
    1. một

    ```swift
    let a = "[[no]]"
    ```
    """

    @Test func findsFrontmatterAndKeys() {
        #expect(substrings(text, .frontmatter) == ["---\nname: x\nmetadata:\n  type: user\n---\n"])
        #expect(substrings(text, .frontmatterKey) == ["name:", "metadata:", "type:"])
    }

    @Test func mapsMultibyteTextToUTF16Ranges() {
        #expect(substrings(text, .heading(level: 1)) == ["# Tiêu đề"])
        #expect(substrings(text, .strong) == ["**đậm**"])
        #expect(substrings(text, .inlineCode) == ["`[[không link]]`"])
        #expect(substrings(text, .link) == ["[web](https://a.b)"])
        #expect(substrings(text, .linkDestination) == ["](https://a.b)"])
        #expect(substrings(text, .codeBlock) == ["```swift\nlet a = \"[[no]]\"\n```"])
    }

    @Test func dimsMarkupPunctuation() {
        let syntax = substrings(text, .syntax)
        #expect(syntax.starts(with: ["# "]))
        #expect(syntax.filter { $0 == "**" }.count == 2)
        #expect(syntax.contains("["))
    }

    @Test func findsWikiLinksOutsideCode() {
        let links = MarkdownHighlighter.spans(in: text).compactMap { span -> String? in
            if case .wikiLink(let target) = span.kind { target } else { nil }
        }
        #expect(links == ["ghi-chú"])
    }

    @Test func marksListAndTaskMarkers() {
        #expect(substrings(text, .taskMarker) == ["- [ ] "])
        #expect(substrings(text, .listMarker) == ["1. "])
    }

    @Test func survivesTextWithoutFrontmatterOrWithUnclosedOne() {
        #expect(substrings("---\nname: x\n# H", .frontmatter).isEmpty)
        #expect(substrings("plain", .strong).isEmpty)
        #expect(MarkdownHighlighter.spans(in: "").isEmpty)
    }
}

@Suite struct MarkdownFormattingTests {
    @Test func wrapsAndUnwrapsSelection() {
        let wrapped = MarkdownFormatting.toggleWrap("a đẹp b", selection: NSRange(location: 2, length: 3), marker: "**")
        #expect(apply(wrapped, to: "a đẹp b") == ("a **đẹp** b", "đẹp"))

        let unwrapOutside = MarkdownFormatting.toggleWrap("a **đẹp** b", selection: NSRange(location: 4, length: 3), marker: "**")
        #expect(apply(unwrapOutside, to: "a **đẹp** b") == ("a đẹp b", "đẹp"))

        let unwrapInside = MarkdownFormatting.toggleWrap("a *x* b", selection: NSRange(location: 2, length: 3), marker: "*")
        #expect(apply(unwrapInside, to: "a *x* b") == ("a x b", "x"))

        let empty = MarkdownFormatting.toggleWrap("ab", selection: NSRange(location: 1, length: 0), marker: "`")
        #expect(apply(empty, to: "ab").0 == "a``b")
        #expect(empty.selection == NSRange(location: 2, length: 0))
    }

    @Test func insertsLinkAndSelectsURL() {
        let edit = MarkdownFormatting.link("see docs", selection: NSRange(location: 4, length: 4))
        #expect(apply(edit, to: "see docs") == ("see [docs](url)", "url"))
    }

    @Test func fencesCodeBlocks() {
        let edit = MarkdownFormatting.codeBlock("x let a", selection: NSRange(location: 2, length: 5))
        #expect(apply(edit, to: "x let a").0 == "x \n```\nlet a\n```")
        #expect(edit.selection == NSRange(location: 6, length: 0))
        #expect(apply(MarkdownFormatting.codeBlock("", selection: NSRange(location: 0, length: 0)), to: "").0 == "```\n```")
    }

    @Test func togglesLinePrefixes() {
        let text = "one\ntwo\nthree"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let numbered = apply(MarkdownFormatting.toggleLinePrefix(text, selection: all, prefix: .numbered), to: text).0
        #expect(numbered == "1. one\n2. two\n3. three")
        let back = MarkdownFormatting.toggleLinePrefix(numbered, selection: NSRange(location: 0, length: (numbered as NSString).length), prefix: .numbered)
        #expect(apply(back, to: numbered).0 == text)

        let heading = MarkdownFormatting.toggleLinePrefix("- item\nnext", selection: NSRange(location: 3, length: 0), prefix: .heading(2))
        #expect(apply(heading, to: "- item\nnext").0 == "## item\nnext")
        #expect(heading.selection == NSRange(location: 4, length: 0))
    }

    @Test func continuesAndEndsLists() {
        let text = "  - [x] done"
        let cont = try! #require(MarkdownFormatting.continueBlock(text, selection: NSRange(location: 12, length: 0)))
        #expect(apply(cont, to: text).0 == "  - [x] done\n  - [ ] ")

        let numbered = try! #require(MarkdownFormatting.continueBlock("9. x", selection: NSRange(location: 4, length: 0)))
        #expect(apply(numbered, to: "9. x").0 == "9. x\n10. ")

        let end = try! #require(MarkdownFormatting.continueBlock("- a\n- ", selection: NSRange(location: 6, length: 0)))
        #expect(apply(end, to: "- a\n- ").0 == "- a\n")

        #expect(MarkdownFormatting.continueBlock("plain", selection: NSRange(location: 5, length: 0)) == nil)
        #expect(MarkdownFormatting.continueBlock("# Head", selection: NSRange(location: 6, length: 0)) == nil)
    }

    @Test func indentsOnlyListLines() {
        let text = "- a\n- b"
        let all = NSRange(location: 0, length: 7)
        let indented = try! #require(MarkdownFormatting.indentList(text, selection: all, outdent: false))
        #expect(apply(indented, to: text).0 == "  - a\n  - b")
        let outdented = try! #require(MarkdownFormatting.indentList("  - a", selection: NSRange(location: 5, length: 0), outdent: true))
        #expect(apply(outdented, to: "  - a").0 == "- a")
        #expect(outdented.selection == NSRange(location: 3, length: 0))
        #expect(MarkdownFormatting.indentList("text", selection: NSRange(location: 0, length: 0), outdent: false) == nil)
    }
}
