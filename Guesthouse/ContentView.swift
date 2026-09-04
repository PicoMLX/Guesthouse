//
//  ContentView.swift
//  Guesthouse
//
//  Created by Ronald Mannak on 9/2/26.
//

import SwiftUI
import GuesthouseCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(DebugRuntimeProbe.self) private var debugProbe

    var body: some View {
        VStack(spacing: 12) {
            switch model.launchState {
            case .checkingEnvironment:
                ProgressView().accessibilityLabel("Checking environment")
                Text("Checking environment…")
            case .ready:
                DashboardView()
            case .interrupted(let interruption):
                Image(systemName: "bolt.slash").imageScale(.large)
                Text(interruption.userMessage)
                // The model owns its reconciliation: a window that closes cannot cancel it,
                // repeated clicks replace the check in flight instead of piling concurrent
                // request streams onto one session until the service refuses them, and a check
                // the Quit sheet owns is not overtaken by one started here.
                Button("Check Environment") { model.startRefresh() }
            case .unavailable(let error):
                Image(systemName: "exclamationmark.triangle").imageScale(.large)
                Text(error.userMessage)
                RecoveryActionRow(actions: error.recoveryActions) { model.startRefresh() }
            }
            #if DEBUG
            Text(debugProbe.result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Debug probe result")
            #endif
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}

/// The error's own recovery actions, in its order. Checking the environment is the one the
/// app can perform today; the others are named so the user knows what the fix will be.
struct RecoveryActionRow: View {
    let actions: [RecoveryAction]
    let check: () -> Void
    /// Clears the failure, where the caller has one to clear. An error whose only recovery is
    /// `.cancel` is otherwise a message with no control at all.
    var dismiss: (() -> Void)?

    var body: some View {
        HStack {
            ForEach(Array(rendered.enumerated()), id: \.offset) { _, action in
                switch action {
                case .retry, .inspectState:
                    Button("Check Environment", action: check)
                case .cancel:
                    if let dismiss {
                        Button("Dismiss", action: dismiss)
                    } else {
                        EmptyView()
                    }
                case .repair, .openConsole, .exportWork, .openSettings, .signInAgain, .freeDiskSpace, .deleteEnvironment, .reinstallApp:
                    Text("\(label(action)) is not available yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One control per distinct behavior. Re-reading the state is all this row can do about
    /// either `retry` or `inspectState`, so an error that prescribes both — a start refused
    /// with `guestNotReachable` — gets one Check Environment rather than two identical buttons
    /// that would each claim to be a different recovery. Repeating the operation itself is the
    /// card's own Start, which the check re-enables once the VM answers as stopped and ready.
    private var rendered: [RecoveryAction] {
        var result: [RecoveryAction] = []
        var checkOffered = false
        for action in actions {
            switch action {
            case .retry, .inspectState:
                guard !checkOffered else { continue }
                checkOffered = true
                result.append(action)
            default:
                result.append(action)
            }
        }
        return result
    }

    private func label(_ action: RecoveryAction) -> String {
        switch action {
        case .retry: "Retry"
        case .inspectState: "Check Environment"
        case .repair: "Repair"
        case .openConsole: "Open Console"
        case .exportWork: "Export Work"
        case .openSettings: "Open Settings"
        case .signInAgain: "Sign In Again"
        case .freeDiskSpace: "Free Disk Space"
        case .deleteEnvironment: "Delete Environment"
        case .reinstallApp: "Reinstall Guesthouse"
        case .cancel: "Cancel"
        }
    }
}

#Preview {
    let backend = FakeRuntimeBackend()
    ContentView()
        .environment(AppModel(backend: backend) { _ in })
        .environment(DebugRuntimeProbe(backend: backend))
}
