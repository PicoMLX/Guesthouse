import Foundation
import GuesthouseCore
import XPC

// The embedded, non-sandboxed runtime service. It answers named operations from the
// sandboxed GUI and nothing else (MVP-PLAN.md §3, "Sandbox and XPC boundary").
//
// Only the `runtimeVersion` operation is implemented here (issue #19). Caller
// authentication and request validation follow in #20; process execution and Tart in #21
// onward. Every other operation is refused with `unsupportedOperation`.

let service = RuntimeService()
let startupLog = ServiceLog(category: "startup")
let listener: XPCListener
do {
    listener = try XPCListener(service: RuntimeService.serviceName) { request in
        request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
            RuntimeEventEnvelope(event: service.handle(message))
        } cancellationHandler: { error in
            service.sessionEnded(error)
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
