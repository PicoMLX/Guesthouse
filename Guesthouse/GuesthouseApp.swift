//
//  GuesthouseApp.swift
//  Guesthouse
//
//  Created by Ronald Mannak on 9/2/26.
//

import SwiftUI
import GuesthouseCore

@main
struct GuesthouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var debugProbe: DebugRuntimeProbe

    init() {
        let backend = AppModel.makeBackend()
        let model = AppModel(backend: backend) { decision in
            NSApp.reply(toApplicationShouldTerminate: decision)
        }
        _model = State(initialValue: model)
        _debugProbe = State(initialValue: DebugRuntimeProbe(backend: backend))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow(model: model, delegate: delegate)
                .environment(model)
                .environment(debugProbe)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Guesthouse") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            #if DEBUG
            CommandMenu("Debug") {
                Button("Runtime Version") { debugProbe.requestRuntimeVersion() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Validate Xcode for Import…") { debugProbe.importXcodeCandidate() }
                Button("Check Environment") { model.startRefresh() }
            }
            #endif
        }
        MenuBarExtra("Guesthouse", systemImage: "desktopcomputer") {
            MenuBarContent(model: model)
        }
    }
}

/// The main window's content plus the Quit sheet, which needs a window to be presented on.
struct MainWindow: View {
    @Bindable var model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .task {
                delegate.openMainWindow = { openWindow(id: "main") }
                delegate.model = model
                // Reconciliation belongs to the model, not to this window: closing the window
                // that started it must not leave the app on "Checking environment".
                model.startRefresh()
            }
            .sheet(isPresented: Binding(get: { model.quitFlow != .idle }, set: { _ in })) {
                QuitSheet(model: model).interactiveDismissDisabled()
            }
    }
}

/// The menu that keeps Guesthouse reachable after the window is closed.
struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.launchState {
        case .checkingEnvironment: Text("Checking environment…")
        case .ready: Text(model.runningEnvironments.isEmpty ? "No development Mac running" : "\(model.runningEnvironments.count) running")
        case .interrupted: Text("Runtime connection lost")
        case .unavailable(let error): Text(error.userMessage)
        }
        Divider()
        Button("Show Guesthouse") { NSApp.activate(); openWindow(id: "main") }
        // The check belongs to the model: a menu that closes must not cancel it, and it is
        // the reconciliation that lifts a suspension a previous failure imposed.
        Button("Check Environment") { model.startRefresh() }
        Divider()
        Button("Quit Guesthouse") { NSApp.terminate(nil) }
    }
}
