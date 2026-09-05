import Foundation
import XPC

// The embedded, non-sandboxed runtime service. It answers named operations from the
// sandboxed GUI and nothing else (MVP-PLAN.md §3, "Sandbox and XPC boundary").
//
// Sessions are accepted only from a peer signed by this team with the app's signing
// identifier; the same requirement is re-checked per message in `RuntimeService`.

let service = RuntimeService()
let listener: XPCListener
do {
    listener = try XPCListener(service: RuntimeService.serviceName, requirement: RuntimeService.peerRequirement) { request in
        request.accept { session in
            service.acceptSession(session)
        }
    }
} catch {
    // A fixed message: the system error's text is opaque and could quote context.
    FileHandle.standardError.write(Data("GuesthouseRuntime: cannot create the XPC listener\n".utf8))
    exit(EXIT_FAILURE)
}
// Accept clients immediately: a missing or hung external executable must never make the XPC
// service look dead. `runtimeVersion` reports a checking state until discovery finishes.
do {
    try listener.activate()
} catch {
    FileHandle.standardError.write(Data("GuesthouseRuntime: cannot activate the XPC listener\n".utf8))
    exit(EXIT_FAILURE)
}
// Discovery happens outside a received-message lifetime, so explicitly hold an XPC transaction.
// Otherwise launchd may idle-exit the service mid-probe and every relaunch would start over at
// `checking`. Balance it on every task exit; normal request/reply transactions stay automatic.
xpc_transaction_begin()
Task {
    defer { xpc_transaction_end() }
    await service.discoverLume()
}
dispatchMain()
