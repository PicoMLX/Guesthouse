//
//  GuesthouseApp.swift
//  Guesthouse
//
//  Created by Ronald Mannak on 9/2/26.
//

import SwiftUI

@main
struct GuesthouseApp: App {
    @State private var debugProbe = DebugRuntimeProbe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(debugProbe)
        }
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Button("Runtime Version") {
                    debugProbe.requestRuntimeVersion()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
        #endif
    }
}
