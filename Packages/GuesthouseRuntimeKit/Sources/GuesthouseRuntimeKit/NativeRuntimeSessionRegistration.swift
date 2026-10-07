import GuesthouseCore
import Synchronization
import XPC

extension NativeRuntimeRequestHandler {
    /// Register original dictionaries without an intermediate Codable message adapter.
    /// The listener still applies its signing requirement; this handler authenticates
    /// every original message before decoding or consuming its reply context (MVP-PLAN.md §3).
    public static func accept(
        _ request: XPCListener.IncomingSessionRequest,
        version: RuntimeVersionInfo, state: RuntimeStateLoader? = nil,
        supervisor: OperationSupervisor = OperationSupervisor(),
        diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void
    ) -> XPCListener.IncomingSessionRequest.Decision {
        acceptNativeRuntimeSession(request) { session in
            NativeRuntimeRequestHandler(session: session, version: version, state: state,
                                        supervisor: supervisor, diagnostic: diagnostic)
        }
    }
}

// Runtime-internal registration seam for native fixtures, never an XPC request API.
// XPC activates the accepted session after the listener callback returns. Bind the
// handler before returning the decision, so its send/cancel closures own that session.
func acceptNativeRuntimeSession<Handler: XPCPeerHandler>(
    _ request: XPCListener.IncomingSessionRequest,
    makeHandler: (XPCSession) -> Handler
) -> XPCListener.IncomingSessionRequest.Decision
where Handler.Input == XPCDictionary, Handler.Output == XPCDictionary {
    let binding = NativeRuntimeSessionBinding<Handler>()
    let (decision, session) = request.accept(
        incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
            binding.handler.withLock { $0 }?.handleIncomingRequest(message)
        }, cancellationHandler: { error in
            // Move the owner out before callback/deinit reentry, and break the session
            // cycle only on actual cancellation. Deferred reply owners remain intact.
            let handler = binding.handler.withLock { value in
                let previous = value; value = nil; return previous
            }
            handler?.handleCancellation(error: error)
        }
    )
    let handler = makeHandler(session)
    binding.handler.withLock { $0 = handler }
    return decision
}

private final class NativeRuntimeSessionBinding<Handler: XPCPeerHandler>: Sendable {
    let handler = Mutex<Handler?>(nil)
}
