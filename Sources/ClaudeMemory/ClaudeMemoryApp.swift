import AppKit
import SwiftUI

@main
struct ClaudeMemoryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Claude Memory", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Project CLAUDE.md files live outside ~/.claude, so the watcher can't see them.
                    model.reload()
                }
        }
        .commands {
            FileCommands()
            CommandGroup(after: .toolbar) {
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasUnsavedChanges == true else { return .terminateNow }
        let alert = NSAlert()
        let names = model?.unsavedFileNames ?? []
        alert.messageText = names.count == 1 ? "\(names[0]) has unsaved changes" : "You have unsaved changes in \(names.count) files"
        let listed = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\nand \(names.count - 5) more" : "")
        alert.informativeText = (names.count > 1 ? listed + "\n\n" : "") + "Quitting now discards your edits. Go back to save them with ⌘S."
        alert.addButton(withTitle: "Keep editing")
        alert.addButton(withTitle: "Discard changes and quit")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
