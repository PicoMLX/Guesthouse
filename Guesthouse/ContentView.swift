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
                Image(systemName: "desktopcomputer").imageScale(.large).foregroundStyle(.tint)
                Text(model.environments.isEmpty ? "No development Mac yet" : "\(model.environments.count) development Mac\(model.environments.count == 1 ? "" : "s")")
            case .interrupted(let interruption):
                Image(systemName: "bolt.slash").imageScale(.large)
                Text(interruption.userMessage)
                Button("Check Environment") { Task { await model.refresh() } }
            case .unavailable(let error):
                Image(systemName: "exclamationmark.triangle").imageScale(.large)
                Text(error.userMessage)
                Button("Check Environment") { Task { await model.refresh() } }
            }
            #if DEBUG
            Text(debugProbe.result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Debug probe result")
            #endif
        }
        .padding()
        .frame(minWidth: 360, minHeight: 200)
    }
}

#Preview {
    let backend = FakeRuntimeBackend()
    ContentView()
        .environment(AppModel(backend: backend) { _ in })
        .environment(DebugRuntimeProbe(backend: backend))
}
