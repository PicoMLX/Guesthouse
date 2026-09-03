import AppKit

/// Bridges AppKit's termination protocol to `AppModel`'s Quit contract.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard quitRequestedBeforeBinding, let model else { return }
            quitRequestedBeforeBinding = false
            presentQuit(model)
        }
    }
    /// Reopens the main window, so the Quit sheet has a host when the window was closed.
    var openMainWindow: (@MainActor () -> Void)?
    /// Quit arrived before the model was bound; it is answered as soon as the binding lands.
    private var quitRequestedBeforeBinding = false

    /// Closing the last window keeps the app alive in the menu bar (MVP-PLAN.md §2).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            quitRequestedBeforeBinding = true
            return .terminateLater
        }
        if model.handleQuitRequest() { return .terminateNow }
        presentQuit(model)
        return .terminateLater
    }

    /// The sheet lives on the main window; with the window closed (Quit from the menu bar
    /// extra, or ⌘Q with no window) it is reopened first, so the confirmation is never lost.
    private func presentQuit(_ model: AppModel) {
        _ = model.handleQuitRequest()
        NSApp.activate()
        let mainWindowVisible = NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
        if !mainWindowVisible { openMainWindow?() }
    }
}
