import Foundation
import XPC

// The embedded, non-sandboxed runtime service. It answers named operations from the
// sandboxed GUI and nothing else (MVP-PLAN.md §3, "Sandbox and XPC boundary").
//
// Only the `runtimeVersion` operation is implemented here (issue #19). Caller
// authentication and request validation follow in #20; process execution and Tart in #21
// onward. Every other operation is refused with `unsupportedOperation`.

let service = RuntimeService()
let listener: XPCListener
do {
    listener = try XPCListener(service: RuntimeService.serviceName) { request in
        request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
            service.handle(message)
        } cancellationHandler: { error in
            service.sessionEnded(error)
        }
    }
} catch {
    FileHandle.standardError.write(Data("GuesthouseRuntime: cannot create listener: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
do {
    try listener.activate()
} catch {
    FileHandle.standardError.write(Data("GuesthouseRuntime: cannot activate listener: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
dispatchMain()
