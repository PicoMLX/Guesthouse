import Foundation

/// Client-local transport cause plus request-specific uncertainty (#19/#112, MVP-PLAN.md §3).
/// Not a wire event, diagnostic attachment, or an operation's terminal result.
public struct RuntimeSessionFailure: Error, Hashable, Sendable, LocalizedError {
    public enum Cause: Hashable, Sendable {
        case connectionLost, malformedResponse, oversizedResponse
        case protocolMismatch(service: Int)
    }

    public let cause: Cause
    public let operationID: OperationID?
    public let mayHaveMutated: Bool
    public var outcomeUnknown: Bool { operationID != nil || mayHaveMutated }

    public init(cause: Cause, operationID: OperationID? = nil, mayHaveMutated: Bool = false) {
        self.cause = cause; self.operationID = operationID; self.mayHaveMutated = mayHaveMutated
    }

    /// Adds context for the SAME request without erasing a learned ID or weakening uncertainty.
    /// The registry stores only cause, never one request's identity on the whole generation.
    public func contextualized(operationID: OperationID? = nil, mayHaveMutated: Bool = false) -> Self {
        Self(cause: cause, operationID: self.operationID ?? operationID,
             mayHaveMutated: self.mayHaveMutated || mayHaveMutated)
    }

    public static func frameFailure(_ failure: RawRuntimeFrame.Failure) -> Self {
        switch failure {
        case .malformed: Self(cause: .malformedResponse)
        case .oversized: Self(cause: .oversizedResponse)
        case .protocolMismatch(let received): Self(cause: .protocolMismatch(service: Int(received)))
        }
    }

    /// For RuntimeEventEnvelope.decode failures only, not arbitrary domain/operation errors.
    public static func decodingFailure(_ error: GuesthouseError) -> Self {
        switch error {
        case .protocolMismatch(_, let service): Self(cause: .protocolMismatch(service: service))
        case .invalidRuntimeReply(.oversized): Self(cause: .oversizedResponse)
        default: Self(cause: .malformedResponse)
        }
    }

    public var userMessage: String {
        let message: String
        switch cause {
        case .connectionLost: message = "Guesthouse lost contact with its runtime service before it answered."
        case .malformedResponse: message = "Guesthouse's runtime service sent an invalid response."
        case .oversizedResponse: message = "Guesthouse's runtime service sent a response exceeding the supported size limit."
        case .protocolMismatch(let service):
            message = GuesthouseError.protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: service).userMessage
        }
        return outcomeUnknown ? message + " The operation may or may not have completed. Inspect its current state before continuing." : message
    }

    /// A read-only connection loss may offer a USER retry; this type never schedules replay.
    public var recoveryActions: [RecoveryAction] {
        if cause == .connectionLost { return outcomeUnknown ? [.inspectState, .cancel] : [.retry, .cancel] }
        return outcomeUnknown ? [.inspectState, .reinstallApp, .cancel] : [.reinstallApp, .cancel]
    }
    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryActions.map(\.title).joined(separator: "; ") }
}
