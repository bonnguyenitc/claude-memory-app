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

/// One animation vocabulary. Movement is dropped under Reduce Motion; opacity and color feedback stays.
struct Motion {
    let animation: Animation
    let isMovement: Bool

    /// Hover highlight on a row or button.
    static let hover = Motion(animation: .easeOut(duration: 0.12), isMovement: false)
    /// Chrome appearing or disappearing in place.
    static let fade = Motion(animation: .easeOut(duration: 0.15), isMovement: false)
    /// Rows entering, leaving or moving. Smooth is critically damped: it settles without overshoot.
    static let layout = Motion(animation: .smooth(duration: 0.3), isMovement: true)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: Motion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion && motion.isMovement ? nil : motion.animation, value: value)
    }
}

extension View {
    /// Animates changes caused by `value` with the app's shared motion, honoring Reduce Motion.
    func motion<Value: Equatable>(_ motion: Motion, value: Value) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }
}
