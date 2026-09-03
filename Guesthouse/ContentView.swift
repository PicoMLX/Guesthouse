//
//  ContentView.swift
//  Guesthouse
//
//  Created by Ronald Mannak on 9/2/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(DebugRuntimeProbe.self) private var debugProbe

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Guesthouse")
            #if DEBUG
            Text(debugProbe.result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Runtime version result")
            #endif
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environment(DebugRuntimeProbe())
}
