import Darwin
import Dispatch
import Foundation
import GuesthouseCore
import GuesthouseRuntimeKit
import OSLog
import XPC

// Embedded, ordinary-user service (#19/#20, MVP-PLAN.md §3). No VM/provider is activated.
private func record(_ event: DiagnosticEvent) {
    Logger(subsystem: "com.starlingprotocol.Guesthouse.Runtime", category: "runtime")
        .notice("\(event.message, privacy: .public)")
}

do {
    let version = RuntimeVersionInfo(
        serviceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        serviceBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
    let listener = try XPCListener(
        service: "com.starlingprotocol.Guesthouse.Runtime",
        requirement: RuntimeCallerAuthentication.listenerRequirement
    ) { request in
        request.accept { session in
            NativeRuntimeRequestHandler(session: session, version: version, diagnostic: record)
        }
    }
    // Default initialization already activates the listener. Never activate it a second time.
    withExtendedLifetime(listener) { dispatchMain() }
} catch {
    record(DiagnosticEvent(operation: .runtimeRequest,
                           outcome: .failed(.executableUnavailable), operationID: UUID()))
    exit(EXIT_FAILURE)
}
