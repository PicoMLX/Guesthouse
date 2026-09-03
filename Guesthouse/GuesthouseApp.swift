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
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(debugProbe)
                .task { delegate.model = model; await model.refresh() }
                .sheet(isPresented: Binding(get: { model.quitFlow != .idle }, set: { _ in })) {
                    QuitSheet(model: model).interactiveDismissDisabled()
                }
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
                Button("Check Environment") { Task { await model.refresh() } }
            }
            #endif
        }
        MenuBarExtra("Guesthouse", systemImage: "desktopcomputer") {
            MenuBarContent(model: model)
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
        Button("Check Environment") { Task { await model.refresh() } }
        Divider()
        Button("Quit Guesthouse") { NSApp.terminate(nil) }
    }
}
