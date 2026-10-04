import Foundation

public struct JSONSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case key, string, number, literal, punctuation
    }

    public let kind: Kind
    /// UTF-16 range, ready for NSTextStorage.
    public let range: NSRange
}

/// Finds the ranges to color in JSON text. Tolerant of invalid input: it never fails, it just colors what it recognizes.
public enum JSONHighlighter {
    public static func spans(in text: String) -> [JSONSpan] {
        let units = Array(text.utf16)
        var spans: [JSONSpan] = []
        var index = 0

        func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
        func isLetter(_ unit: UInt16) -> Bool { (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A) }

        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x22: // "
                let start = index
                index += 1
                while index < units.count, units[index] != 0x22, units[index] != 0x0A {
                    index += units[index] == 0x5C ? 2 : 1
                }
                index = min(index + 1, units.count)
                var next = index
                while next < units.count, units[next] == 0x20 || units[next] == 0x09 || units[next] == 0x0A || units[next] == 0x0D { next += 1 }
                let isKey = next < units.count && units[next] == 0x3A
                spans.append(JSONSpan(kind: isKey ? .key : .string, range: NSRange(location: start, length: index - start)))
            case 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A: // { } [ ] , :
                spans.append(JSONSpan(kind: .punctuation, range: NSRange(location: index, length: 1)))
                index += 1
            case _ where isDigit(unit) || unit == 0x2D:
                let start = index
                index += 1
                while index < units.count, isDigit(units[index]) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(units[index]) { index += 1 }
                spans.append(JSONSpan(kind: .number, range: NSRange(location: start, length: index - start)))
            case _ where isLetter(unit):
                let start = index
                while index < units.count, isLetter(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                if ["true", "false", "null"].contains(word) {
                    spans.append(JSONSpan(kind: .literal, range: NSRange(location: start, length: index - start)))
                }
            default:
                index += 1
            }
        }
        return spans
    }
}
