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
    /// queries, or by throwing when the connection to the service is lost. A throw after an
    /// operation was accepted means its outcome is unknown; the caller must inspect actual
    /// state before retrying.
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error>
}

/// Thrown by a backend when the connection dropped before the request reported a result.
///
/// Carries the same presentation contract as `GuesthouseError`: when host state may have
/// changed the user is told the outcome is unknown and offered an inspection, never a blind
/// retry (MVP-PLAN.md §3). That covers an operation that was in flight and a mutating request
/// that may have reached the service before it was accepted. A read-only query names no
/// operation, changed nothing, and is offered the retry that its own failure calls for.
public struct RuntimeConnectionInterrupted: Error, Hashable, Sendable, LocalizedError {
    public let operationID: OperationID?
    /// Whether a request that changes the host may already have reached the service.
    ///
    /// A request interrupted before its `accepted` reply has no operation id, but the service
    /// may still have received it and started or journaled the mutation. Such a request has an
    /// unknown outcome just as an accepted one does, so it is never offered a blind retry.
    public let mayHaveMutated: Bool

    public init(operationID: OperationID? = nil, mayHaveMutated: Bool = false) {
        self.operationID = operationID
        self.mayHaveMutated = mayHaveMutated
    }

    /// Whether host state may have changed, so it has to be inspected before anything else.
    private var outcomeUnknown: Bool { operationID != nil || mayHaveMutated }

    public var userMessage: String {
        outcomeUnknown
            ? "Guesthouse lost contact with its runtime service. The operation may or may not have completed."
            : "Guesthouse lost contact with its runtime service before it answered."
    }

    public var recoveryMessage: String {
        outcomeUnknown
            ? "Check the environment before doing anything else."
            : "Ask again once the service is back."
    }

    public var recoveryActions: [RecoveryAction] {
        outcomeUnknown ? [.inspectState, .cancel] : [.retry]
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }

    /// The equivalent structured error when the interrupted operation is known.
    public var guesthouseError: GuesthouseError? {
        operationID.map { .operationOutcomeUnknown($0) }
    }
}
