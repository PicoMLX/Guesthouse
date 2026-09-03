import Foundation

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
///
/// Carries the same presentation contract as `GuesthouseError`: the user is told the outcome
/// is unknown and offered an inspection, never a blind retry (MVP-PLAN.md §3).
public struct RuntimeConnectionInterrupted: Error, Hashable, Sendable, LocalizedError {
    public let operationID: OperationID?

    public init(operationID: OperationID? = nil) {
        self.operationID = operationID
    }

    public var userMessage: String {
        "Guesthouse lost contact with its runtime service. The operation may or may not have completed."
    }

    public var recoveryMessage: String {
        "Check the environment before doing anything else."
    }

    public var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }

    /// The equivalent structured error when the interrupted operation is known.
    public var guesthouseError: GuesthouseError? {
        operationID.map { .operationOutcomeUnknown($0) }
    }
}
