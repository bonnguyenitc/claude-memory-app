import MemoryCore
import SwiftUI

/// Every layout number derives from a 4pt base unit.
enum Spacing {
    static let unit: CGFloat = 4

    static let xxs = unit * 1
    static let xs = unit * 2
    static let s = unit * 3
    static let m = unit * 4
    static let l = unit * 6
    static let xl = unit * 8
}

enum Radius {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
}

/// One color per meaning: unsaved is the accent, warnings are orange, only destructive is red.
enum Semantic {
    static let unsaved = Color.accentColor
    static let warning = Color.orange
    static let ok = Color.green
}

extension MemoryType {
    var symbol: String {
        switch self {
        case .user: "person"
        case .feedback: "bubble.left"
        case .project: "folder"
        case .reference: "link"
        }
    }
}
