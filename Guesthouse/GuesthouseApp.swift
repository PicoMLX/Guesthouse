import AppKit
import SwiftUI
import GuesthouseClientKit
import GuesthouseCore

@main
struct GuesthouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var quit: QuitCoordinator

    init() {
        let model = AppModel(backend: AppRuntimeConfiguration.makeBackend())
        _model = State(initialValue: model)
        _quit = State(initialValue: QuitCoordinator(model: model) { NSApp.reply(toApplicationShouldTerminate: $0) })
    }

    var body: some Scene {
        // One primary window avoids duplicate Quit sheets on the shared coordinator (#75).
        Window("Guesthouse", id: "main") {
            MainWindow(model: model, quit: quit, delegate: delegate)
        }
        .defaultSize(width: 720, height: 800)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Guesthouse") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        MenuBarExtra("Guesthouse", systemImage: "desktopcomputer") {
            GuesthouseMenu(model: model, quit: quit, delegate: delegate)
        }
    }
}

/// Only development builds can substitute simulation through a launch environment.
enum AppRuntimeConfiguration {
    static func makeBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeBackend {
        #if DEBUG
        if environment["XCTestConfigurationFilePath"] != nil || environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" {
            return FakeRuntimeBackend()
        }
        #endif
        return RuntimeClient()
    }
}

private struct MainWindow: View {
    let model: AppModel, quit: QuitCoordinator, delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { DashboardView(model: model, quit: quit).padding(20) }
            Divider()
            DisclosureGroup("Setup checks") { ContentView().frame(minHeight: 300) }.padding(.horizontal, 20)
        }
        .onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
            delegate.coordinator = quit
            if quit.flow == .idle { model.checkEnvironments() }
        }
        .sheet(isPresented: Binding(get: { quit.flow != .idle && quit.flow != .terminating }, set: { _ in })) {
            QuitSheet(coordinator: quit).interactiveDismissDisabled()
        }
    }
}

private struct GuesthouseMenu: View {
    let model: AppModel, quit: QuitCoordinator, delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.environmentSummary)
        Divider()
        Button("Show Guesthouse") { delegate.presentMainWindow() }
        Button("Check environment") { model.checkEnvironments() }
            .disabled(model.isChecking || model.isStarting || quit.flow != .idle)
        Divider()
        Button("Quit Guesthouse") { NSApp.terminate(nil) }
        .onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
            delegate.coordinator = quit
        }
    }
}
