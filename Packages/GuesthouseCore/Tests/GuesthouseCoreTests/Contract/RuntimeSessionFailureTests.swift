import Testing
@testable import GuesthouseCore

struct RuntimeSessionFailureTests {
    @Test(arguments: [RuntimeSessionFailure.Cause.connectionLost, .malformedResponse, .oversizedResponse, .protocolMismatch(service: 99)],
          [(false, false), (true, false), (false, true), (true, true)])
    func causeAndOutcomeAreIndependent(cause: RuntimeSessionFailure.Cause, context: (Bool, Bool)) {
        let (accepted, preacceptMutation) = context
        let id = accepted ? OperationID() : nil
        let failure = RuntimeSessionFailure(cause: cause, operationID: id, mayHaveMutated: preacceptMutation)
        #expect(failure.outcomeUnknown == (accepted || preacceptMutation))
        #expect(failure.recoveryActions.contains(.inspectState) == failure.outcomeUnknown)
        #expect(failure.recoveryActions.contains(.retry) == (cause == .connectionLost && !failure.outcomeUnknown))
        #expect(failure.userMessage.contains("may or may not have completed") == failure.outcomeUnknown)
        #expect(failure.contextualized().operationID == id)
        #expect(failure.contextualized().mayHaveMutated == preacceptMutation)
        #expect(failure.errorDescription == failure.userMessage)
        #expect(failure.recoverySuggestion?.isEmpty == false)
    }

    @Test func addingContextCannotEraseOrReplaceLearnedIdentity() {
        let id = OperationID()
        let failure = RuntimeSessionFailure(cause: .malformedResponse, operationID: id, mayHaveMutated: true)
        let preserved = failure.contextualized(operationID: OperationID(), mayHaveMutated: false)
        #expect(preserved == failure)
        #expect(RuntimeSessionFailure(cause: .oversizedResponse).contextualized(operationID: id).operationID == id)
    }

    @Test func nativeAndNestedFailuresRetainOnlyClosedCauses() {
        #expect(RuntimeSessionFailure.frameFailure(.malformed).cause == .malformedResponse)
        #expect(RuntimeSessionFailure.frameFailure(.oversized).cause == .oversizedResponse)
        #expect(RuntimeSessionFailure.frameFailure(.protocolMismatch(received: 99)).cause == .protocolMismatch(service: 99))
        #expect(RuntimeSessionFailure.decodingFailure(.invalidRuntimeReply(.malformed)).cause == .malformedResponse)
        #expect(RuntimeSessionFailure.decodingFailure(.invalidRuntimeReply(.oversized)).cause == .oversizedResponse)
        #expect(RuntimeSessionFailure.decodingFailure(.protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: 99)).cause == .protocolMismatch(service: 99))
    }
}
