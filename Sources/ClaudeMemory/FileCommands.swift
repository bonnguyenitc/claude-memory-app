import SwiftUI

/// What the frontmost editor lets the File menu do; nil means not available right now.
struct EditorActions {
    var save: (() -> Void)?
    var showInFinder: (() -> Void)?
    var trash: (() -> Void)?
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
}

/// Menu-bar twins of the editor toolbar, so no action lives only behind a button.
struct FileCommands: Commands {
    @FocusedValue(\.editorActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions?.save?() }
                .keyboardShortcut("s")
                .disabled(actions?.save == nil)
            Button("Show in Finder") { actions?.showInFinder?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.showInFinder == nil)
            Divider()
            Button("Move to Trash") { actions?.trash?() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.trash == nil)
        }
    }
}
