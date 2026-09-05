import Foundation
import GuesthouseCore
import XPC

// The embedded, non-sandboxed runtime service. It answers named operations from the
// sandboxed GUI and nothing else (MVP-PLAN.md §3, "Sandbox and XPC boundary").
//
// Sessions are accepted only from a peer signed by this team with the app's signing
// identifier; the same requirement is re-checked per message in `RuntimeService`.

let service = RuntimeService()
let startupLog = ServiceLog(category: "startup")
let listener: XPCListener
do {
    listener = try XPCListener(service: RuntimeService.serviceName, requirement: RuntimeService.peerRequirement) { request in
        request.accept { session in
            service.acceptSession(session)
        }
    }
} catch {
    // A fixed message: the system error's text is opaque and could quote context.
    startupLog.error(RedactedLine(literal: "GuesthouseRuntime: cannot create the XPC listener"))
    exit(EXIT_FAILURE)
}
do {
    try listener.activate()
} catch {
    startupLog.error(RedactedLine(literal: "GuesthouseRuntime: cannot activate the XPC listener"))
    exit(EXIT_FAILURE)
}
dispatchMain()
