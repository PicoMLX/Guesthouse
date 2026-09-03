import AppKit

/// Bridges AppKit's termination protocol to `AppModel`'s Quit contract.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Closing the last window keeps the app alive in the menu bar (MVP-PLAN.md §2).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.handleQuitRequest() { return .terminateNow }
        NSApp.activate()
        return .terminateLater
    }
}
