//
//  ContentView.swift
//  Guesthouse
//
//  Created by Ronald Mannak on 9/2/26.
//

import SwiftUI
import GuesthouseClientKit
import GuesthouseCore

struct ContentView: View {
    @State private var check: Task<Void, Never>?
    @State private var outcome: RuntimeVersionQuery.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Guesthouse").font(.title)
            Text("Check the connection to Guesthouse’s embedded runtime service. This does not create or start a development Mac.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Check runtime connection", action: startCheck)
                    .disabled(check != nil)
                    .accessibilityIdentifier("checkRuntimeConnection")
                if check != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking runtime connection")
                    Button("Cancel", action: cancelCheck).disabled(check?.isCancelled == true)
                }
            }
            if let outcome {
                VStack(alignment: .leading, spacing: 8) {
                    switch outcome {
                    case .success(let info):
                        Text("Runtime service responded.").font(.headline)
                        Text("Version \(info.serviceVersion ?? "unknown"), build \(info.serviceBuild ?? "unknown"), protocol \(info.protocolVersion.rawValue).")
                        Text("VM, provider and Xcode readiness have not been checked.")
                            .foregroundStyle(.secondary)
                    case .failure(let error):
                        Text(error.userMessage)
                        Text(error.recoveryMessage).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("runtimeConnectionResult")
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 260, alignment: .topLeading)
        .onDisappear(perform: cancelCheck)
    }

    private func startCheck() {
        guard check == nil else { return }
        outcome = nil
        check = Task {
            let result = await RuntimeVersionQuery.run()
            outcome = Task.isCancelled ? .failure(.canceled) : result
            check = nil
        }
    }

    private func cancelCheck() {
        guard let check else { return }
        check.cancel()
        // Keep the check occupied until its structured children and connection have finished.
        // A late result cannot race a new check, and repeated cancel/start cannot stack sessions.
        outcome = .failure(.canceled)
    }
}

#Preview {
    ContentView()
}
