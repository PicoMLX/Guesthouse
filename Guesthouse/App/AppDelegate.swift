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
        // A window in the Dock cannot show a sheet, and activating the app does not bring it
        // back out, so it is restored explicitly before anything is decided from what is
        // visible. Without this a Quit from the menu bar extra or the Dock could attach the
        // confirmation to a minimized window and leave AppKit waiting on `.terminateLater`
        // with no choice on screen (MVP-PLAN.md §2).
        let mainWindows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") ?? false }
        for window in mainWindows where window.isMiniaturized { window.deminiaturize(nil) }
        // The reopen is asked for whenever no main window is on screen, which includes one
        // still coming back from the Dock: for a single-instance `Window` scene that is the
        // same window being raised, never a second one.
        if !mainWindows.contains(where: \.isVisible) { openMainWindow?() }
    }
}
