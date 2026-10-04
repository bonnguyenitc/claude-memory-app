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
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Quitting now will discard them."
        alert.addButton(withTitle: "Stay")
        alert.addButton(withTitle: "Discard and quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
