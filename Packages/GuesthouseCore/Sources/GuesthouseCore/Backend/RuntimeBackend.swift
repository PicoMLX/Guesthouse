/// The one seam between the GUI and whatever executes host operations.
///
/// The real implementation is the XPC `RuntimeClient` (issue #19); the fake below drives
/// previews and tests. Keep this small: MVP-PLAN.md §3 warns against a plugin system before
/// a second backend exists.
public protocol RuntimeBackend: Sendable {
    /// Sends one request and streams the service's events for it.
    ///
    /// The stream ends after `completed` or `failed` for operations, after the reply for
    /// queries, or by throwing when the connection to the service is lost. A thrown error
    /// means the outcome is unknown; the caller must inspect actual state before retrying.
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error>
}

/// Thrown by a backend when the connection dropped before the operation reported a result.
public struct RuntimeConnectionInterrupted: Error, Hashable, Sendable {
    public let operationID: OperationID?

    public init(operationID: OperationID? = nil) {
        self.operationID = operationID
    }
}
