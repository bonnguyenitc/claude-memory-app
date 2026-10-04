import Foundation
import Testing
@testable import MemoryCore

@Suite struct ClaudeSettingsTests {
    private let sample = """
    {
      "model": "sonnet",
      "nested": { "autoMemoryEnabled": true },
      "permissions": { "allow": [] }
    }
    """

    @Test func validatesJsonObjects() {
        #expect(ClaudeSettings.validationError(in: sample) == nil)
        #expect(ClaudeSettings.validationError(in: "") == nil)
        #expect(ClaudeSettings.validationError(in: "{ \"a\": }") != nil)
        #expect(ClaudeSettings.validationError(in: "[1]") != nil)
    }

    @Test func readsOnlyTopLevelBooleans() {
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: sample) == nil)
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: "{\"autoMemoryEnabled\": false}") == false)
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: "{\"autoMemoryEnabled\": 1}") == nil)
    }

    @Test func insertsMissingKeyAndKeepsTheRest() throws {
        let updated = try #require(ClaudeSettings.setting("autoMemoryEnabled", to: false, in: """
        {
          "model": "sonnet"
        }
        """))
        #expect(ClaudeSettings.validationError(in: updated) == nil)
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: updated) == false)
        #expect(updated.contains("\"model\": \"sonnet\""))
    }

    @Test func changesExistingValueInPlace() throws {
        let text = "{\n  \"autoMemoryEnabled\": true,\n  \"model\": \"x\"\n}\n"
        let updated = try #require(ClaudeSettings.setting("autoMemoryEnabled", to: false, in: text))
        #expect(updated == "{\n  \"autoMemoryEnabled\": false,\n  \"model\": \"x\"\n}\n")
    }

    @Test func handlesEmptyObjectAndEmptyFile() throws {
        let fromEmptyObject = try #require(ClaudeSettings.setting("autoMemoryEnabled", to: true, in: "{}"))
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: fromEmptyObject) == true)
        let fromEmptyFile = try #require(ClaudeSettings.setting("autoMemoryEnabled", to: true, in: ""))
        #expect(ClaudeSettings.bool("autoMemoryEnabled", in: fromEmptyFile) == true)
    }

    @Test func refusesInvalidJson() {
        #expect(ClaudeSettings.setting("autoMemoryEnabled", to: true, in: "{ nope") == nil)
    }
}

@Suite struct ClaudeSettingsStringTests {
    @Test func setsInsertsAndReplacesStrings() throws {
        let inserted = try #require(ClaudeSettings.setting("autoMemoryDirectory", toString: "~/mem \"x\"", in: "{\n  \"model\": \"a\"\n}"))
        #expect(ClaudeSettings.string("autoMemoryDirectory", in: inserted) == "~/mem \"x\"")
        let replaced = try #require(ClaudeSettings.setting("autoMemoryDirectory", toString: "/new", in: inserted))
        #expect(ClaudeSettings.string("autoMemoryDirectory", in: replaced) == "/new")
        #expect(ClaudeSettings.string("model", in: replaced) == "a")
    }

    @Test func emptyValueRemovesTheKeyInEveryPosition() throws {
        for text in [
            "{\"autoMemoryDirectory\": \"/a\", \"model\": \"m\"}",
            "{\"model\": \"m\", \"autoMemoryDirectory\": \"/a\"}",
            "{\n  \"autoMemoryDirectory\": \"/a\"\n}",
        ] {
            let updated = try #require(ClaudeSettings.setting("autoMemoryDirectory", toString: "", in: text))
            #expect(ClaudeSettings.validationError(in: updated) == nil)
            #expect(ClaudeSettings.string("autoMemoryDirectory", in: updated) == nil)
        }
        #expect(ClaudeSettings.setting("autoMemoryDirectory", toString: "", in: "{\"a\": 1}") == "{\"a\": 1}")
    }

    @Test func validatesMemoryDirectory() {
        #expect(ClaudeSettings.memoryDirectoryError("") == nil)
        #expect(ClaudeSettings.memoryDirectoryError("/Users/me/mem") == nil)
        #expect(ClaudeSettings.memoryDirectoryError("~/mem") == nil)
        #expect(ClaudeSettings.memoryDirectoryError("relative/mem") != nil)
        #expect(ClaudeSettings.memoryDirectoryError("~") != nil)
    }
}

@Suite struct MemoryIndexLimitTests {
    @Test func warnsOnlyPastTheLoadedLimits() {
        #expect(MemoryIndex.truncationWarning(for: String(repeating: "- a\n", count: 200)) == nil)
        #expect(MemoryIndex.truncationWarning(for: String(repeating: "- a\n", count: 201)) != nil)
        #expect(MemoryIndex.truncationWarning(for: String(repeating: "x", count: 25_001)) != nil)
    }
}

@Suite struct JSONFormatTests {
    @Test func reindentsKeepingOrderAndLiterals() throws {
        let messy = "{\"b\":1.50,\"a\"  :[1,{\"x\":\"he said \\\"hi, {ok}\\\"\"},[]],\"e\":{} , \"z\":null}"
        let expected = """
        {
          "b": 1.50,
          "a": [
            1,
            {
              "x": "he said \\"hi, {ok}\\""
            },
            []
          ],
          "e": {},
          "z": null
        }

        """
        #expect(try #require(ClaudeSettings.formatted(messy)) == expected)
    }

    @Test func isIdempotentAndRefusesInvalidInput() throws {
        let once = try #require(ClaudeSettings.formatted("{\"a\":[1,2],\"b\":{\"c\":true}}"))
        #expect(ClaudeSettings.formatted(once) == once)
        #expect(ClaudeSettings.formatted("{ nope") == nil)
        #expect(ClaudeSettings.formatted("  ") == nil)
    }
}

@Suite struct JSONHighlighterTests {
    private func kinds(_ text: String) -> [JSONSpan.Kind] {
        JSONHighlighter.spans(in: text).map(\.kind).filter { $0 != .punctuation }
    }

    @Test func separatesKeysFromStringValues() {
        #expect(kinds("{\"a\": \"b\", \"n\": -1.5e3, \"t\": true, \"z\": null}")
            == [.key, .string, .key, .number, .key, .literal, .key, .literal])
    }

    @Test func rangesAreUTF16AndHandleEscapes() throws {
        let text = "{\"é\\\"x\": 1}"
        let key = try #require(JSONHighlighter.spans(in: text).first { $0.kind == .key })
        #expect((text as NSString).substring(with: key.range) == "\"é\\\"x\"")
    }

    @Test func toleratesInvalidInput() {
        #expect(kinds("{\"a\": \"unterminated") == [.key, .string])
        #expect(JSONHighlighter.spans(in: "").isEmpty)
    }
}
