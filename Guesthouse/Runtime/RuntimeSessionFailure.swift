import Foundation
import GuesthouseCore

/// A session contract failure, separate from whether an operation may have changed the host.
/// No failure here makes a mutation safe to replay (MVP-PLAN.md §3).
nonisolated struct RuntimeSessionFailure: Error, Hashable, Sendable, LocalizedError {
    enum Cause: Hashable, Sendable {
        case protocolMismatch(RuntimeEventEnvelope.ProtocolMismatch)
        case malformedResponse
    }

    let cause: Cause
    let interruption: RuntimeConnectionInterrupted

    init(cause: Cause, operationID: OperationID? = nil, mayHaveMutated: Bool = false) {
        self.cause = cause
        interruption = RuntimeConnectionInterrupted(operationID: operationID, mayHaveMutated: mayHaveMutated)
    }

    init?(decoding error: any Error) {
        if let failure = error as? Self {
            self = failure
        } else if let mismatch = error as? RuntimeEventEnvelope.ProtocolMismatch {
            self.init(cause: .protocolMismatch(mismatch))
        } else if error is DecodingError {
            self.init(cause: .malformedResponse)
        } else {
            return nil
        }
    }

    func contextualized(operationID: OperationID? = nil, mayHaveMutated: Bool = false) -> Self {
        Self(cause: cause, operationID: operationID, mayHaveMutated: mayHaveMutated)
    }

    var protocolMismatch: GuesthouseError? {
        guard case .protocolMismatch(let mismatch) = cause else { return nil }
        return mismatch.error
    }

    private var outcomeUnknown: Bool { interruption.operationID != nil || interruption.mayHaveMutated }

    var errorDescription: String? {
        let message = protocolMismatch?.userMessage
            ?? "Guesthouse's runtime service sent a response this app cannot read. Reinstall Guesthouse to repair this."
        return outcomeUnknown ? "\(message) \(interruption.userMessage)" : message
    }

    var recoveryActions: [RecoveryAction] {
        outcomeUnknown ? [.inspectState, .reinstallApp, .cancel] : [.reinstallApp, .cancel]
    }
}
