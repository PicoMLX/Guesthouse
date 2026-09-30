import AppKit

/// Keep app-owned runtime checks alive after the window closes (MVP-PLAN.md §2).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: QuitCoordinator? {
        didSet {
            guard pendingQuit, let coordinator else { return }
            pendingQuit = false
            _ = coordinator.requestQuit()
            presentMainWindow()
        }
    }
    var openMainWindow: (@MainActor () -> Void)?
    private var pendingQuit = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { pendingQuit = true; return .terminateLater }
        if coordinator.requestQuit() { return .terminateNow }
        presentMainWindow()
        return .terminateLater
    }

    func presentMainWindow() {
        NSApp.activate()
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        if !windows.contains(where: \.isVisible) { openMainWindow?() }
    }
}
