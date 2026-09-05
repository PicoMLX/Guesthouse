import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

struct RuntimeSessionFailureTests {
    @Test(arguments: [
        RuntimeSessionFailure.Cause.protocolMismatch(RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99))),
        .malformedResponse
    ], [RuntimeRequest.runtimeVersion, .startEnvironment(EnvironmentID(), StartOptions())])
    func failedReplyPreservesContractCauseAndPreacceptOutcome(cause: RuntimeSessionFailure.Cause, request: RuntimeRequest) async throws {
        let failure = RuntimeSessionFailure(cause: cause)
        let session = RefusingSession(.contractFailure(failure))
        let transport = XPCRuntimeTransport(connect: { _, _ in session })
        let client = RuntimeClient(transport: transport)
        let caught = try #require(await #expect(throws: RuntimeSessionFailure.self) {
            for try await _ in client.send(request) { Issue.record("A failed reply produced an event") }
        })
        #expect(caught.cause == cause)
        #expect(caught.interruption.operationID == nil)
        #expect(caught.interruption.mayHaveMutated == request.mutatesHost)
        #expect(caught.recoveryActions.contains(.inspectState) == request.mutatesHost)
        #expect(!caught.recoveryActions.contains(.retry))
        #expect(session.cancelReasons == ["reply failed"], "No automatic request replay")
    }

    @Test(arguments: [
        RuntimeSessionFailure.Cause.protocolMismatch(RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99))),
        .malformedResponse
    ])
    func acceptedMutationRetainsIdentityAndUnknownOutcome(cause: RuntimeSessionFailure.Cause) async throws {
        let transport = FakeTransport(.acceptThenContractFailure(RuntimeSessionFailure(cause: cause)))
        let client = RuntimeClient(transport: transport)
        var iterator = client.send(.startEnvironment(EnvironmentID(), StartOptions())).makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(transport.preparedID))
        let caught = try #require(await #expect(throws: RuntimeSessionFailure.self) {
            try await iterator.next()
        })
        #expect(caught.cause == cause)
        #expect(caught.interruption.guesthouseError == .operationOutcomeUnknown(transport.preparedID))
        #expect(caught.recoveryActions == [.inspectState, .reinstallApp, .cancel])
        #expect(transport.sentCount == 1, "No fabricated terminal event or automatic mutation replay")
    }

    @Test func retirementCauseStaysWithItsGenerationAndIsReportedOnce() throws {
        let registry = SessionRegistry<NSObject>()
        let (_, old) = registry.session { _ in NSObject() }
        let failure = RuntimeSessionFailure(cause: .protocolMismatch(RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99))))
        let reports = Counter()
        let incoming = Counter()
        registry.setHandlers(incoming: { _ in incoming.increment() }, interrupted: { received in
            #expect(received == failure)
            reports.increment()
        })
        _ = registry.retire(old, failure: failure)
        let (_, replacement) = registry.session { _ in NSObject() }
        #expect(registry.retire(old, failure: RuntimeSessionFailure(cause: .malformedResponse)) == nil)
        let oldReply = Box<Result<RuntimeEvent, any Error>>()
        registry.deliverReply(.success(.accepted(OperationID())), from: old) { oldReply.value = $0 }
        guard case .failure(let error) = try #require(oldReply.value) else {
            Issue.record("A late acceptance must remain an unknown outcome")
            return
        }
        #expect(error as? RuntimeSessionFailure == failure)
        let event = RuntimeEvent.completed(OperationID())
        registry.deliverReply(.success(event), from: replacement) { result in
            #expect((try? result.get()) == event)
        }
        registry.deliverIncoming(event, from: old)
        registry.deliverIncoming(event, from: replacement)
        #expect(incoming.value == 1)
        #expect(reports.value == 1)
    }

    @Test(arguments: [
        RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99)),
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Malformed fixture"))
    ] as [any Error])
    func ordinaryRetirementDoesNotEraseALateRepliesKnownCause(error: any Error) throws {
        let registry = SessionRegistry<NSObject>()
        let (_, old) = registry.session { _ in NSObject() }
        let reports = Counter()
        registry.setHandlers(incoming: { _ in }, interrupted: { _ in reports.increment() })
        _ = registry.retire(old)
        let (_, replacement) = registry.session { _ in NSObject() }
        let reply = Box<Result<RuntimeEvent, any Error>>()
        registry.deliverReply(.failure(error), from: old) { reply.value = $0 }
        guard case .failure(let received) = try #require(reply.value) else {
            Issue.record("A stale failed reply must remain a failure")
            return
        }
        #expect(received as? RuntimeSessionFailure == RuntimeSessionFailure(decoding: error))
        #expect(reports.value == 1)
        registry.deliverReply(.success(.completed(OperationID())), from: replacement) { result in
            if case .failure = result { Issue.record("An old failure affected the replacement") }
        }
    }
}
