import Foundation

/// Runtime-only live owner and its real persisted correlation. No readiness/settlement proof.
struct LumeProbeLaunch: Sendable {
    let intent: LumeLaunchIntent
    let run: ProcessRun
}

/// Fixed introspection policy retained from #84. Constructing options grants no executable
/// authority: StateStore alone supplies a strictly reverified executable at the launch boundary.
/// Never accepts GUI paths/flags, VM operations, an inherited environment or raw diagnostics.
enum LumeProbeInvocation {
    static func make(executable: URL, command: LumeLaunchIntent.Command,
                     storage: RuntimeStorage) throws -> ProcessInvocation {
        let arguments: [String]
        switch command {
        case .version: arguments = ["--version"]
        case .createHelp: arguments = ["create", "--help"]
        case .detachedRunHelp: arguments = ["run", "--detach", "--help"]
        case .attachHelp: arguments = ["attach", "--help"]
        }
        return ProcessInvocation(executable: executable, arguments: arguments,
            environment: try storage.environmentForLumeProbe(), currentDirectory: try storage.location(for: .staging),
            timeout: .seconds(5), terminationGracePeriod: .seconds(1), maximumOutputBytes: 1 << 20,
            capturing: [.stdout], observation: .forkHistory)
    }
}
